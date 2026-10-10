//! What git's `fsck` finds wrong with an object's bytes, and how much each
//! finding matters.
//!
//! An object that arrives over the wire was written by someone else, and a
//! well-formed name says nothing about well-formed content: a tree whose
//! entries are out of order, or name `.git`, or a commit with two authors,
//! hashes as happily as any other. git checks what it receives when
//! `transfer.fsckObjects` asks (`fetch.fsckObjects`, `receive.fsckObjects`),
//! and so does relic; a failure is a refusal that names the problem with
//! git's own message id.
//!
//! The checks are `fsck.c`'s, line for line: every message id git has,
//! each with git's level — fatal, error, warning, information, ignored —
//! which `Rules` takes from `fsck.<msg-id>`, `fetch.fsck.<msg-id>` and
//! `receive.fsck.<msg-id>`, with objects named in a `skipList` left alone.
//! A tree's `.gitmodules` and `.gitattributes` blobs are gathered in
//! `Found` and read by `checkBlob`, as git reads them once the pack is in.
//! Before any of it, a commit or tag git's parser cannot read is refused,
//! as `index-pack` refuses it, whatever the levels say.
//!
//! When nothing is configured, relic still checks what it receives, with
//! git's levels and a tree naming `.`, `..` or `.git` in any spelling
//! raised from a warning to an error: `baseline`. A checkout refuses such a
//! path anyway, and an old repository's style warnings stay warnings.

const ErrorNamespace = @This();
const std = @import("std");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("object.zig");
const config_mod = @import("../config/config.zig");
const gitmodules = @import("../config/gitmodules.zig");
const safepath = @import("../names.zig").path;
const ref_names = @import("../names.zig").ref;
const warning = @import("../report.zig").warning;

const Oid = hash.Oid;
const Kind = hash.Kind;

/// One problem, named as git's `fsck.<msg-id>` names it, in git's order.
/// The ones about refs are here so that configuration naming them is
/// read as git reads it; no object check reports them.
pub const Problem = enum {
    // Fatal.
    nul_in_header,
    unterminated_header,
    // Errors.
    bad_header_continuation,
    bad_date,
    bad_date_overflow,
    bad_email,
    bad_gpgsig,
    bad_head_target,
    bad_name,
    bad_object_sha1,
    bad_packed_ref_entry,
    bad_packed_ref_header,
    bad_parent_sha1,
    bad_referent_name,
    bad_ref_content,
    bad_ref_filetype,
    bad_ref_name,
    bad_ref_oid,
    bad_timezone,
    bad_tree,
    bad_tree_sha1,
    bad_type,
    duplicate_entries,
    gitattributes_blob,
    gitattributes_large,
    gitattributes_line_length,
    gitattributes_missing,
    gitmodules_blob,
    gitmodules_large,
    gitmodules_missing,
    gitmodules_name,
    gitmodules_path,
    gitmodules_symlink,
    gitmodules_update,
    gitmodules_url,
    missing_author,
    missing_committer,
    missing_email,
    missing_name_before_email,
    missing_object,
    missing_space_before_date,
    missing_space_before_email,
    missing_tag,
    missing_tag_entry,
    missing_tree,
    missing_type,
    missing_type_entry,
    multiple_authors,
    packed_ref_entry_not_terminated,
    packed_ref_unsorted,
    tree_not_sorted,
    unknown_type,
    zero_padded_date,
    // Warnings.
    bad_reftable_table_name,
    empty_name,
    full_pathname,
    has_dot,
    has_dotdot,
    has_dotgit,
    large_pathname,
    null_sha1,
    nul_in_commit,
    zero_padded_filemode,
    // Information: reported as warnings, ignored unless raised.
    bad_filemode,
    bad_tag_name,
    empty_packed_refs_file,
    gitattributes_symlink,
    gitignore_symlink,
    gitmodules_parse,
    mailmap_symlink,
    missing_tagger_entry,
    ref_missing_newline,
    symlink_ref,
    symref_target_is_not_a_ref,
    trailing_ref_content,
    // Ignored unless raised.
    extra_header_entry,

    pub const count = @typeInfo(Problem).@"enum".field_names.len;

    /// git's message id: `treeNotSorted`, `badTimezone`, and so on, which
    /// is what `fsck.<msg-id>` configuration and git's own messages use.
    pub fn id(problem: Problem) []const u8 {
        return ids[@backingInt(problem)];
    }

    /// The id as configuration spells it once read: lower case, no
    /// underscores, which is what git matches a configured name against.
    pub fn fromConfigName(name: []const u8) ?Problem {
        for (std.enums.values(Problem)) |problem| {
            if (std.ascii.eqlIgnoreCase(problem.id(), name)) return problem;
        }
        return null;
    }

    /// The level git gives the problem when nothing says otherwise.
    pub fn defaultLevel(problem: Problem) Level {
        const at = @backingInt(problem);
        if (at <= @backingInt(Problem.unterminated_header)) return .fatal;
        if (at <= @backingInt(Problem.zero_padded_date)) return .@"error";
        if (at <= @backingInt(Problem.zero_padded_filemode)) return .warn;
        if (at <= @backingInt(Problem.trailing_ref_content)) return .info;
        return .ignore;
    }

    /// What git says after the id, without what it names.
    pub fn text(problem: Problem) []const u8 {
        return switch (problem) {
            .nul_in_header, .unterminated_header => "unterminated header",
            .bad_tree_sha1 => "invalid 'tree' line format - bad sha1",
            .bad_parent_sha1 => "invalid 'parent' line format - bad sha1",
            .bad_object_sha1 => "invalid 'object' line format - bad sha1",
            .missing_tree => "invalid format - expected 'tree' line",
            .missing_author => "invalid format - expected 'author' line",
            .multiple_authors => "invalid format - multiple 'author' lines",
            .missing_committer => "invalid format - expected 'committer' line",
            .missing_name_before_email => "invalid author/committer line - missing space before email",
            .missing_email => "invalid author/committer line - missing email",
            .bad_name => "invalid author/committer line - bad name",
            .missing_space_before_email => "invalid author/committer line - missing space before email",
            .bad_email => "invalid author/committer line - bad email",
            .missing_space_before_date => "invalid author/committer line - missing space before date",
            .bad_date => "invalid author/committer line - bad date",
            .zero_padded_date => "invalid author/committer line - zero-padded date",
            .bad_date_overflow => "invalid author/committer line - date causes integer overflow",
            .bad_timezone => "invalid author/committer line - bad time zone",
            .nul_in_commit => "NUL byte in the commit object body",
            .missing_object => "invalid format - expected 'object' line",
            .missing_type_entry => "invalid format - expected 'type' line",
            .missing_type => "invalid format - unexpected end after 'type' line",
            .bad_type => "invalid 'type' value",
            .missing_tag_entry => "invalid format - expected 'tag' line",
            .missing_tag => "invalid format - unexpected end after 'type' line",
            .bad_tag_name => "invalid 'tag' name: ",
            .missing_tagger_entry => "invalid format - expected 'tagger' line",
            .bad_gpgsig => "invalid format - unexpected end after 'gpgsig' or 'gpgsig-sha256' line",
            .bad_header_continuation => "invalid format - unexpected end in 'gpgsig' or 'gpgsig-sha256' continuation line",
            .extra_header_entry => "invalid format - extra header(s) after 'tagger'",
            .bad_tree => "cannot be parsed as a tree",
            .null_sha1 => "contains entries pointing to null sha1",
            .full_pathname => "contains full pathnames",
            .empty_name => "contains empty pathname",
            .has_dot => "contains '.'",
            .has_dotdot => "contains '..'",
            .has_dotgit => "contains '.git'",
            .zero_padded_filemode => "contains zero-padded file modes",
            .bad_filemode => "contains bad file modes",
            .duplicate_entries => "contains duplicate file entries",
            .tree_not_sorted => "not properly sorted",
            .large_pathname => "contains excessively large pathname",
            .gitmodules_symlink => ".gitmodules is a symbolic link",
            .gitattributes_symlink => ".gitattributes is a symlink",
            .gitignore_symlink => ".gitignore is a symlink",
            .mailmap_symlink => ".mailmap is a symlink",
            .gitmodules_large => ".gitmodules too large to parse",
            .gitmodules_parse => "could not parse gitmodules blob",
            .gitmodules_name => "disallowed submodule name: ",
            .gitmodules_url => "disallowed submodule url: ",
            .gitmodules_path => "disallowed submodule path: ",
            .gitmodules_update => "disallowed submodule update setting: ",
            .gitmodules_missing => "unable to read .gitmodules blob",
            .gitmodules_blob => "non-blob found at .gitmodules",
            .gitattributes_large => ".gitattributes too large to parse",
            .gitattributes_line_length => ".gitattributes has too long lines to parse",
            .gitattributes_missing => "unable to read .gitattributes blob",
            .gitattributes_blob => "non-blob found at .gitattributes",
            .unknown_type => "unknown type (internal fsck error)",
            else => "",
        };
    }
};

const ids = blk: {
    @setEvalBranchQuota(20_000);
    var out: [Problem.count][]const u8 = undefined;
    for (std.enums.values(Problem), 0..) |problem, i| {
        const snake = @tagName(problem);
        var camel: [snake.len]u8 = undefined;
        var len: usize = 0;
        var upper = false;
        for (snake) |c| {
            if (c == '_') {
                upper = true;
                continue;
            }
            camel[len] = if (upper) std.ascii.toUpper(c) else c;
            len += 1;
            upper = false;
        }
        const final = camel[0..len].*;
        out[i] = &final;
    }
    break :blk out;
};

/// How much a problem matters.
pub const Level = enum {
    /// An error that may not be lowered: the object cannot be read safely.
    fatal,
    @"error",
    warn,
    /// Reported as a warning, and not at all unless asked.
    info,
    ignore,

    /// A level as configuration writes it: `error`, `warn` or `ignore`.
    pub fn parse(text_: []const u8) ?Level {
        if (std.mem.eql(u8, text_, "error")) return .@"error";
        if (std.mem.eql(u8, text_, "warn")) return .warn;
        if (std.mem.eql(u8, text_, "ignore")) return .ignore;
        return null;
    }
};

/// Whose configuration the rules come from: `git fsck`'s own, a fetch's
/// or clone's, or a push received.
pub const Scope = enum {
    fsck,
    fetch,
    receive,
};

/// Errors from reading the rules.
pub const LoadError = errors: {
    break :errors error{
        /// `fsck.<msg-id>` names no message git has. Under `fetch.fsck.` and
        /// `receive.fsck.` git warns and goes on, and so does this.
        UnknownFsckMessage,
        /// A level other than `error`, `warn` or `ignore`.
        UnknownFsckLevel,
        /// A fatal problem lowered below an error, which git refuses.
        FsckFatalLowered,
        /// `largePathname`'s length is not a number.
        InvalidFsckValue,
        /// A `skipList` that could not be read.
        SkipListUnreadable,
        /// A `skipList` line that is not one full object name.
        InvalidSkipListEntry,
        /// A setting holds a value that does not decode.
        MalformedValue,
        /// A `<scope>.fsck.<msg-id>` with no value.
        MissingValue,
    } || Allocator.Error || Io.Cancelable;
};

/// The levels the checks report at, the objects they leave alone, and the
/// longest name a tree may carry.
pub const Rules = struct {
    pub const Error = ErrorNamespace.Error;

    /// git's strict mode, which a fetch, a clone and a received push use:
    /// every warning is an error unless configured otherwise.
    strict: bool = false,
    /// What configuration set, by problem.
    levels: [Problem.count]?Level = @splat(null),
    /// Objects a `skipList` names, which no finding is reported for.
    skip: Oid.Set = .empty,
    /// `largePathname`'s bound: the longest tree entry name.
    max_entry_len: usize = 4096,

    /// Release the skip list.
    pub fn deinit(r: *Rules, gpa: Allocator) void {
        r.skip.deinit(gpa);
        r.* = undefined;
    }

    /// The level `problem` is reported at.
    pub fn level(r: *const Rules, problem: Problem) Level {
        if (r.levels[@backingInt(problem)]) |configured| return configured;
        const default = problem.defaultLevel();
        if (r.strict and default == .warn) return .@"error";
        return default;
    }

    /// Set the level of the problem `name` names, as `fsck.<name>=<value>`
    /// does: `value` is `error`, `warn` or `ignore`, and for
    /// `largePathname` may carry `:<length>`.
    pub fn set(r: *Rules, name: []const u8, value: []const u8) LoadError!void {
        const problem = Problem.fromConfigName(name) orelse return error.UnknownFsckMessage;
        var level_text = value;
        if (problem == .large_pathname) {
            if (std.mem.findScalar(u8, value, ':')) |colon| {
                level_text = value[0..colon];
                const n = config_mod.parseInt(value[colon + 1 ..]) catch return error.InvalidFsckValue;
                r.max_entry_len = std.math.cast(usize, n) orelse return error.InvalidFsckValue;
            }
        }
        const new = Level.parse(level_text) orelse return error.UnknownFsckLevel;
        if (new != .@"error" and problem.defaultLevel() == .fatal) return error.FsckFatalLowered;
        r.levels[@backingInt(problem)] = new;
    }

    /// Whether `oid` is on the skip list.
    pub fn skips(r: *const Rules, oid: Oid) bool {
        return r.skip.contains(oid);
    }

    /// Add the names in the skip list at `path`: one full name a line,
    /// with `#` comments, blank lines and surrounding space allowed, as
    /// git reads `fsck.skipList`.
    pub fn readSkipList(r: *Rules, gpa: Allocator, io: Io, kind: Kind, path: []const u8) LoadError!void {
        const text_ = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.SkipListUnreadable,
        };
        defer gpa.free(text_);
        var lines = std.mem.splitScalar(u8, text_, '\n');
        while (lines.next()) |raw| {
            var line = raw;
            if (std.mem.findScalar(u8, line, '#')) |at| line = line[0..at];
            line = std.mem.trim(u8, line, " \t\r\x0b\x0c");
            if (line.len == 0) continue;
            if (line.len != kind.hexLen()) return error.InvalidSkipListEntry;
            const oid = Oid.parse(kind, line) catch return error.InvalidSkipListEntry;
            try r.skip.put(gpa, oid, {});
        }
    }

    /// The rules `config` gives `scope`: `<scope>.fsck.<msg-id>` and
    /// `<scope>.fsck.skipList` in the order they are set, each skip list
    /// read whole, a relative path from the current directory. `strict`
    /// for a fetch, a clone or a received push, as git checks them.
    /// `fetch.fsck.` and `receive.fsck.` names no message has are left out
    /// and said in `warnings`, as git warns; `fsck.` ones are refused.
    pub const LoadOptions = struct { kind: Kind, scope: Scope = .fsck, strict: bool = false, sink: ?Sink = null };
    pub fn load(gpa: Allocator, io: Io, config: *const config_mod.Config, options: LoadOptions) LoadError!Rules {
        const strict = options.strict;
        var rules: Rules = .{ .strict = strict };
        errdefer rules.deinit(gpa);
        try rules.configure(gpa, io, config, .{ .kind = options.kind, .scope = options.scope, .sink = options.sink });
        return rules;
    }

    /// `load`, over rules already made: `baseline` takes the
    /// configuration this way.
    pub const ConfigureOptions = struct { kind: Kind, scope: Scope = .fsck, sink: ?Sink = null };
    pub fn configure(r: *Rules, gpa: Allocator, io: Io, config: *const config_mod.Config, options: ConfigureOptions) LoadError!void {
        const kind = options.kind;
        const scope = options.scope;
        const sink = options.sink;
        for (config.entries.items) |entry| {
            if (!entryUnder(entry, scope)) continue;
            const raw = entry.value orelse return error.MissingValue;
            const value = raw;
            if (std.ascii.eqlIgnoreCase(entry.name, "skiplist")) {
                var path = value;
                var expanded: ?[]u8 = null;
                defer if (expanded) |e| gpa.free(e);
                if (std.mem.startsWith(u8, value, "~/")) if (config.context.home) |home| {
                    expanded = try gpa.print("{s}/{s}", .{ home, value[2..] });
                    path = expanded.?;
                };
                try r.readSkipList(gpa, io, kind, path);
                continue;
            }
            if (scope != .fsck) {
                // git checks the level first and warns of a name it does
                // not know, so `largePathname=warn:<n>` is refused here.
                if (Level.parse(value) == null) return error.UnknownFsckLevel;
                if (Problem.fromConfigName(entry.name) == null) {
                    if (sink) |s| try s.unknown(s.context, entry.name);
                    continue;
                }
            }
            try r.set(entry.name, value);
        }
    }
};

fn entryUnder(entry: config_mod.Entry, scope: Scope) bool {
    return switch (scope) {
        .fsck => !entry.has_subsection and std.mem.eql(u8, entry.section, "fsck"),
        .fetch => entry.has_subsection and std.mem.eql(u8, entry.section, "fetch") and std.mem.eql(u8, entry.subsection, "fsck"),
        .receive => entry.has_subsection and std.mem.eql(u8, entry.section, "receive") and std.mem.eql(u8, entry.subsection, "fsck"),
    };
}

/// relic's checks when nothing asks for git's: git's levels, with a tree
/// naming `.`, `..` or `.git` refused.
pub const baseline: Rules = blk: {
    var r: Rules = .{};
    r.levels[@backingInt(Problem.has_dot)] = .@"error";
    r.levels[@backingInt(Problem.has_dotdot)] = .@"error";
    r.levels[@backingInt(Problem.has_dotgit)] = .@"error";
    break :blk r;
};

/// Whether `<scope>.fsckObjects` — falling back on `transfer.fsckObjects`
/// — asks for git's checks: `null` when neither is set. `git fsck` checks
/// whatever is set.
pub fn wanted(config: *const config_mod.Config, scope: Scope) config_mod.ValueError!?bool {
    const own = switch (scope) {
        .fsck => return true,
        .fetch => "fetch.fsckobjects",
        .receive => "receive.fsckobjects",
    };
    if (config.find(own) != null) {
        const value = try config.getBool(own, false);
        return value;
    }
    if (config.find("transfer.fsckobjects") != null) {
        const value = try config.getBool("transfer.fsckobjects", false);
        return value;
    }
    return null;
}

/// Errors from `forTransfer`.
pub const ForTransferError = LoadError || config_mod.ValueError;

/// Borrowed format and transfer scope.
pub const TransferInputs = struct { kind: Kind, scope: Scope };
/// Explicit policy and an optional warning sink.
pub const TransferOptions = struct { explicit: ?bool = null, sink: ?Sink = null };

/// The rules a fetch or clone with `config` checks with, or `null` for
/// none: `explicit` when the caller says, otherwise `fetch.fsckObjects` or
/// `transfer.fsckObjects`. On, they are git's strict checks with
/// `fetch.fsck.*`; unset, `baseline` with `fetch.fsck.*`; off, none, as git
/// checks nothing then. The result's skip list is `gpa`'s.
pub fn forTransfer(gpa: Allocator, io: Io, config: ?*const config_mod.Config, inputs: TransferInputs, options: TransferOptions) ForTransferError!?Rules {
    const kind = inputs.kind;
    const scope = inputs.scope;
    const explicit = options.explicit;
    const sink = options.sink;
    const on = explicit orelse if (config) |c| try wanted(c, scope) else null;
    var rules = baseline;
    if (on) |yes| {
        if (!yes) return null;
        rules = .{ .strict = true };
    }
    errdefer rules.deinit(gpa);
    if (config) |c| try rules.configure(gpa, io, c, .{ .kind = kind, .scope = scope, .sink = sink });
    return rules;
}

/// One problem found.
pub const Finding = struct {
    /// The object it is about.
    oid: Oid,
    /// `null` when git's parser cannot read the commit or tag at all,
    /// which `index-pack` refuses before any check.
    problem: ?Problem,
    /// `error` or `warn`: what the rules made of it.
    level: Level,
    /// What git's message names after the text: a submodule's name, url,
    /// path or update, a tag's name. Borrowed for the call.
    detail: []const u8 = "",

    /// git's message: `<msg-id>: <text>`. The result is `gpa`'s.
    pub fn message(f: Finding, gpa: Allocator) Allocator.Error![]u8 {
        const problem = f.problem orelse return gpa.dupe(u8, "cannot be parsed");
        return gpa.print("{s}: {s}{s}", .{ problem.id(), problem.text(), f.detail });
    }
};

/// Where warnings go, and names configuration gave that no message has.
pub const Sink = struct {
    context: *anyopaque,
    warning: *const fn (context: *anyopaque, finding: Finding) Allocator.Error!void,
    unknown: *const fn (context: *anyopaque, name: []const u8) Allocator.Error!void,
};

/// A `Sink` that keeps what it is given in `warnings`, as git prints it.
/// One task at a time.
pub const ToWarnings = struct {
    warnings: ?*warning.Warnings,

    pub fn sink(t: *ToWarnings) Sink {
        return .{ .context = t, .warning = noteFinding, .unknown = noteUnknown };
    }

    fn noteFinding(context: *anyopaque, finding: Finding) Allocator.Error!void {
        const t: *ToWarnings = @ptrCast(@alignCast(context)); // safe: the context is the ToWarnings the sink was made from
        try note(t.warnings, finding);
    }

    fn noteUnknown(context: *anyopaque, name: []const u8) Allocator.Error!void {
        const t: *ToWarnings = @ptrCast(@alignCast(context)); // safe: the context is the ToWarnings the sink was made from
        try warning.note(t.warnings, .{ .fsck_unknown_message = name });
    }
};

/// Keep `finding` in `to`, as git's warning words it.
pub fn note(to: ?*warning.Warnings, finding: Finding) Allocator.Error!void {
    const w = to orelse return;
    var hex: [hash.max_hex_len]u8 = undefined;
    const message = try finding.message(w.arena.allocator());
    try w.add(.{ .fsck = .{ .object = finding.oid.hex(&hex), .message = message } });
}

/// The `.gitmodules` and `.gitattributes` blobs trees name, which git
/// reads once every object has come.
pub const Found = struct {
    pub const Error = ErrorNamespace.Error;

    modules: Oid.Set = .empty,
    attributes: Oid.Set = .empty,

    pub fn deinit(f: *Found, gpa: Allocator) void {
        f.modules.deinit(gpa);
        f.attributes.deinit(gpa);
        f.* = undefined;
    }
};

/// What a found blob is read as.
pub const Special = enum { modules, attributes };

const Reporter = struct {
    rules: *const Rules,
    oid: Oid,
    sink: ?Sink,
    first: ?Finding = null,

    /// Report `problem`; whether it is an error, which stops a commit's or
    /// tag's checks where git's stop.
    fn report(r: *Reporter, problem: Problem, detail: []const u8) Allocator.Error!bool {
        if (r.rules.skips(r.oid)) return false;
        switch (r.rules.level(problem)) {
            .ignore => return false,
            .warn, .info => {
                if (r.sink) |s| try s.warning(s.context, .{ .oid = r.oid, .problem = problem, .level = .warn, .detail = detail });
                return false;
            },
            .fatal, .@"error" => {
                if (r.first == null) r.first = .{ .oid = r.oid, .problem = problem, .level = .@"error" };
                return true;
            },
        }
    }
};

/// Borrowed object identity, type and content.
pub const ObjectInputs = struct { kind: Kind, oid: Oid, type: object.Type, bytes: []const u8 };
/// Optional special-blob collection and warning sink.
pub const CheckOptions = struct { found: ?*Found = null, sink: ?Sink = null };

/// The first error in object `oid` of type `t`, whose content is `bytes`,
/// as git's `index-pack` finds it with `rules`: a commit or tag git's
/// parser cannot read, then `checkObject`. `null` when there is none.
pub fn inspect(gpa: Allocator, rules: *const Rules, inputs: ObjectInputs, options: CheckOptions) Allocator.Error!?Finding {
    const kind = inputs.kind;
    const oid = inputs.oid;
    const t = inputs.type;
    const bytes = inputs.bytes;
    if (!parsesAsGit(kind, t, bytes)) return .{ .oid = oid, .problem = null, .level = .@"error" };
    return checkObject(gpa, rules, inputs, options);
}

/// The first error git's `fsck_object` finds in an object with `rules`,
/// or `null`. Warnings go to `sink`; a tree's `.gitmodules` and
/// `.gitattributes` go to `found`, for `checkBlob`. A blob is checked by
/// `checkBlob`, once it is known to be one of those.
pub fn checkObject(gpa: Allocator, rules: *const Rules, inputs: ObjectInputs, options: CheckOptions) Allocator.Error!?Finding {
    const kind = inputs.kind;
    const oid = inputs.oid;
    const t = inputs.type;
    const bytes = inputs.bytes;
    const found = options.found;
    const sink = options.sink;
    var r: Reporter = .{ .rules = rules, .oid = oid, .sink = sink };
    switch (t) {
        .blob => {},
        .tree => try checkTree(gpa, &r, kind, bytes, found),
        .commit => _ = try checkCommit(&r, kind, bytes),
        .tag => _ = try checkTag(&r, kind, bytes),
    }
    return r.first;
}

/// git's `parse_commit_buffer` and `parse_tag_buffer`, which `index-pack`
/// runs before any check and dies on.
fn parsesAsGit(kind: Kind, t: object.Type, bytes: []const u8) bool {
    const hex_len = kind.hexLen();
    switch (t) {
        .blob, .tree => return true,
        .commit => {
            const tree_entry_len = hex_len + 5;
            const parent_entry_len = hex_len + 7;
            if (bytes.len <= tree_entry_len + 1 or !std.mem.startsWith(u8, bytes, "tree ") or bytes[tree_entry_len] != '\n') return false;
            _ = Oid.parse(kind, bytes[5..tree_entry_len]) catch return false;
            var at = tree_entry_len + 1;
            while (at + parent_entry_len < bytes.len and std.mem.startsWith(u8, bytes[at..], "parent ")) {
                if (bytes.len <= at + parent_entry_len + 1 or bytes[at + parent_entry_len] != '\n') return false;
                _ = Oid.parse(kind, bytes[at + 7 .. at + parent_entry_len]) catch return false;
                at += parent_entry_len + 1;
            }
            return true;
        },
        .tag => {
            if (bytes.len < hex_len + 24) return false;
            if (!std.mem.startsWith(u8, bytes, "object ")) return false;
            _ = Oid.parse(kind, bytes[7 .. 7 + hex_len]) catch return false;
            var at = 7 + hex_len;
            if (bytes[at] != '\n') return false;
            at += 1;
            if (!std.mem.startsWith(u8, bytes[at..], "type ")) return false;
            at += 5;
            const nl = std.mem.findScalarPos(u8, bytes, at, '\n') orelse return false;
            if (nl - at >= 20) return false;
            _ = object.Type.parse(bytes[at..nl]) catch return false;
            at = nl + 1;
            if (!(at + 4 < bytes.len and std.mem.startsWith(u8, bytes[at..], "tag "))) return false;
            at += 4;
            _ = std.mem.findScalarPos(u8, bytes, at, '\n') orelse return false;
            return true;
        },
    }
}

/// The byte at `i`, or NUL past the end, as git's NUL-terminated buffers
/// read.
fn byteAt(bytes: []const u8, i: usize) u8 {
    return if (i < bytes.len) bytes[i] else 0;
}

const s_ifmt: u32 = 0o170000;
const s_ifdir: u32 = 0o040000;
const s_iflnk: u32 = 0o120000;

fn checkTree(gpa: Allocator, r: *Reporter, kind: Kind, bytes: []const u8, found: ?*Found) Allocator.Error!void {
    const raw_len = kind.rawLen();
    var has_null_sha1 = false;
    var has_full_path = false;
    var has_empty_name = false;
    var has_dot = false;
    var has_dotdot = false;
    var has_dotgit = false;
    var has_zero_pad = false;
    var has_bad_modes = false;
    var has_dup_entries = false;
    var not_properly_sorted = false;
    var has_large_name = false;
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(gpa);

    if (bytes.len == 0) return;
    var rest = bytes;
    var entry = decodeEntry(rest, raw_len) orelse {
        _ = try r.report(.bad_tree, "");
        return;
    };
    var previous: ?TreeEntry = null;
    while (rest.len != 0) {
        const name = entry.name;
        has_null_sha1 = has_null_sha1 or std.mem.allEqual(u8, entry.oid, 0);
        has_full_path = has_full_path or std.mem.findScalar(u8, name, '/') != null;
        has_empty_name = has_empty_name or name.len == 0;
        has_dot = has_dot or std.mem.eql(u8, name, ".");
        has_dotdot = has_dotdot or std.mem.eql(u8, name, "..");
        has_dotgit = has_dotgit or safepath.isHfsDot(name, "git") or safepath.isNtfsDotGit(name);
        has_zero_pad = has_zero_pad or rest[0] == '0';
        has_large_name = has_large_name or name.len > r.rules.max_entry_len;

        const is_link = entry.mode & s_ifmt == s_iflnk;
        if (safepath.isHfsDot(name, "gitmodules") or safepath.isNtfsDot(name, "gitmodules", "gi7eba")) {
            if (!is_link) {
                if (found) |f| try f.modules.put(gpa, entry.oidValue(kind), {});
            } else _ = try r.report(.gitmodules_symlink, "");
        }
        if (safepath.isHfsDot(name, "gitattributes") or safepath.isNtfsDot(name, "gitattributes", "gi7d29")) {
            if (!is_link) {
                if (found) |f| try f.attributes.put(gpa, entry.oidValue(kind), {});
            } else _ = try r.report(.gitattributes_symlink, "");
        }
        if (is_link) {
            if (safepath.isHfsDot(name, "gitignore") or safepath.isNtfsDot(name, "gitignore", "gi250a")) _ = try r.report(.gitignore_symlink, "");
            if (safepath.isHfsDot(name, "mailmap") or safepath.isNtfsDot(name, "mailmap", "maba30")) _ = try r.report(.mailmap_symlink, "");
        }
        var backslash = std.mem.findScalar(u8, name, '\\');
        while (backslash) |at| {
            const after = name[at + 1 ..];
            has_dotgit = has_dotgit or safepath.isNtfsDotGit(after);
            if (safepath.isNtfsDot(after, "gitmodules", "gi7eba")) {
                if (!is_link) {
                    if (found) |f| try f.modules.put(gpa, entry.oidValue(kind), {});
                } else _ = try r.report(.gitmodules_symlink, "");
            }
            backslash = if (std.mem.findScalar(u8, after, '\\')) |next| at + 1 + next else null;
        }

        rest = rest[entry.len..];
        const next = if (rest.len != 0) decodeEntry(rest, raw_len) else null;
        if (rest.len != 0 and next == null) {
            _ = try r.report(.bad_tree, "");
            break;
        }

        switch (entry.mode) {
            0o100755, 0o100644, s_iflnk, s_ifdir, 0o160000 => {},
            // Nonstandard, but early git wrote it.
            0o100664 => if (r.rules.strict) {
                has_bad_modes = true;
            },
            else => has_bad_modes = true,
        }
        if (previous) |prev| switch (try verifyOrdered(gpa, prev, entry, &candidates)) {
            .ordered => {},
            .unordered => not_properly_sorted = true,
            .duplicate => has_dup_entries = true,
        };
        previous = entry;
        if (next) |n| entry = n;
    }

    if (has_null_sha1) _ = try r.report(.null_sha1, "");
    if (has_full_path) _ = try r.report(.full_pathname, "");
    if (has_empty_name) _ = try r.report(.empty_name, "");
    if (has_dot) _ = try r.report(.has_dot, "");
    if (has_dotdot) _ = try r.report(.has_dotdot, "");
    if (has_dotgit) _ = try r.report(.has_dotgit, "");
    if (has_zero_pad) _ = try r.report(.zero_padded_filemode, "");
    if (has_bad_modes) _ = try r.report(.bad_filemode, "");
    if (has_dup_entries) _ = try r.report(.duplicate_entries, "");
    if (not_properly_sorted) _ = try r.report(.tree_not_sorted, "");
    if (has_large_name) _ = try r.report(.large_pathname, "");
}

const TreeEntry = struct {
    /// git's raw mode, kept to sixteen bits as git keeps it.
    mode: u16,
    name: []const u8,
    oid: []const u8,
    /// The whole entry's length.
    len: usize,

    fn oidValue(e: TreeEntry, kind: Kind) Oid {
        return Oid.fromRaw(kind, e.oid) catch unreachable; // unreachable: decodeEntry took exactly rawLen bytes
    }
};

/// git's `decode_tree_entry`: `<octal mode> <name>\0<raw name>`, the mode
/// read until its space and the name until its NUL.
fn decodeEntry(bytes: []const u8, raw_len: usize) ?TreeEntry {
    if (bytes.len < raw_len + 3 or bytes[bytes.len - (raw_len + 1)] != 0) return null;
    if (bytes[0] == ' ') return null;
    var mode: u32 = 0;
    var at: usize = 0;
    while (true) : (at += 1) {
        const c = byteAt(bytes, at);
        if (c == ' ') break;
        if (c < '0' or c > '7') return null;
        mode = (mode << 3) +% (c - '0');
    }
    at += 1;
    const nul = std.mem.findScalarPos(u8, bytes, at, 0) orelse return null;
    if (nul == at) return null;
    if (nul + 1 + raw_len > bytes.len) return null;
    return .{
        .mode = @truncate(mode),
        .name = bytes[at..nul],
        .oid = bytes[nul + 1 .. nul + 1 + raw_len],
        .len = nul + 1 + raw_len,
    };
}

const Order = enum { ordered, unordered, duplicate };

fn lessThanSlash(c: u8) bool {
    return c != 0 and c < '/';
}

/// git's `verify_ordered`: names compared as if a tree's had a `/` on the
/// end, with names that may meet a twin further on kept on a stack.
fn verifyOrdered(gpa: Allocator, a: TreeEntry, b: TreeEntry, candidates: *std.ArrayList([]const u8)) Allocator.Error!Order {
    const len = @min(a.name.len, b.name.len);
    switch (std.mem.order(u8, a.name[0..len], b.name[0..len])) {
        .lt => return .ordered,
        .gt => return .unordered,
        .eq => {},
    }
    var c1 = byteAt(a.name, len);
    var c2 = byteAt(b.name, len);
    if (c1 == 0 and c2 == 0) return .duplicate;
    if (c1 == 0 and a.mode & s_ifmt == s_ifdir) c1 = '/';
    if (c2 == 0 and b.mode & s_ifmt == s_ifdir) c2 = '/';
    if (c1 == 0 and lessThanSlash(c2)) {
        try candidates.append(gpa, a.name);
    } else if (c2 == '/' and lessThanSlash(c1)) {
        while (candidates.pop()) |f_name| {
            if (!std.mem.startsWith(u8, b.name, f_name)) continue;
            const p = b.name[f_name.len..];
            if (p.len == 0) return .duplicate;
            if (lessThanSlash(p[0])) {
                try candidates.append(gpa, f_name);
                break;
            }
        }
    }
    return if (c1 < c2) .ordered else .unordered;
}

/// git's `verify_headers`: the headers end in a blank line, or at least
/// in a line break, and hold no NUL. Whether the checks go on.
fn verifyHeaders(r: *Reporter, bytes: []const u8) Allocator.Error!bool {
    for (bytes, 0..) |c, i| {
        switch (c) {
            0 => return !try r.report(.nul_in_header, ""),
            '\n' => if (i + 1 < bytes.len and bytes[i + 1] == '\n') return true,
            else => {},
        }
    }
    if (bytes.len != 0 and bytes[bytes.len - 1] == '\n') return true;
    return !try r.report(.unterminated_header, "");
}

/// Where a header's object name ends, when it is one: `hexLen` hex digits
/// then a line break.
fn oidLine(kind: Kind, bytes: []const u8, at: usize) bool {
    const end = at + kind.hexLen();
    if (end >= bytes.len or bytes[end] != '\n') return false;
    _ = Oid.parse(kind, bytes[at..end]) catch return false;
    return true;
}

fn nextLine(bytes: []const u8, at: usize) usize {
    const nl = std.mem.findScalarPos(u8, bytes, @min(at, bytes.len), '\n') orelse return bytes.len;
    return nl + 1;
}

fn checkCommit(r: *Reporter, kind: Kind, bytes: []const u8) Allocator.Error!bool {
    if (!try verifyHeaders(r, bytes)) return true;
    var at: usize = 0;
    if (!std.mem.startsWith(u8, bytes, "tree ")) return r.report(.missing_tree, "");
    at = 5;
    if (!oidLine(kind, bytes, at)) {
        if (try r.report(.bad_tree_sha1, "")) return true;
    }
    at = nextLine(bytes, at);
    while (at < bytes.len and std.mem.startsWith(u8, bytes[at..], "parent ")) {
        at += 7;
        if (!oidLine(kind, bytes, at)) {
            if (try r.report(.bad_parent_sha1, "")) return true;
        }
        at = nextLine(bytes, at);
    }
    var authors: usize = 0;
    while (at < bytes.len and std.mem.startsWith(u8, bytes[at..], "author ")) {
        authors += 1;
        at += 7;
        if (try checkIdent(r, bytes, &at)) return true;
    }
    if (authors < 1) {
        if (try r.report(.missing_author, "")) return true;
    } else if (authors > 1) {
        if (try r.report(.multiple_authors, "")) return true;
    }
    if (!(at < bytes.len and std.mem.startsWith(u8, bytes[at..], "committer "))) return r.report(.missing_committer, "");
    at += 10;
    if (try checkIdent(r, bytes, &at)) return true;
    if (std.mem.findScalar(u8, bytes, 0) != null) {
        if (try r.report(.nul_in_commit, "")) return true;
    }
    return false;
}

fn checkTag(r: *Reporter, kind: Kind, bytes: []const u8) Allocator.Error!bool {
    if (!try verifyHeaders(r, bytes)) return true;
    var at: usize = 0;
    if (!std.mem.startsWith(u8, bytes, "object ")) return r.report(.missing_object, "");
    at = 7;
    if (!oidLine(kind, bytes, at)) {
        if (try r.report(.bad_object_sha1, "")) return true;
    }
    at = nextLine(bytes, at);
    if (!(at < bytes.len and std.mem.startsWith(u8, bytes[at..], "type "))) return r.report(.missing_type_entry, "");
    at += 5;
    const type_end = std.mem.findScalarPos(u8, bytes, at, '\n') orelse return r.report(.missing_type, "");
    if (object.Type.parse(bytes[at..type_end])) |_| {} else |_| {
        if (try r.report(.bad_type, "")) return true;
    }
    at = type_end + 1;
    if (!(at < bytes.len and std.mem.startsWith(u8, bytes[at..], "tag "))) return r.report(.missing_tag_entry, "");
    at += 4;
    const tag_end = std.mem.findScalarPos(u8, bytes, at, '\n') orelse return r.report(.missing_tag, "");
    const tag_name = bytes[at..tag_end];
    var ref_buf: [4096]u8 = undefined;
    const ref_name = std.mem.print(&ref_buf, "refs/tags/{s}", .{tag_name}) catch "";
    if (ref_name.len == 0 or !ref_names.checkFormat(ref_name, .{})) {
        if (try r.report(.bad_tag_name, tag_name)) return true;
    }
    at = tag_end + 1;
    if (!(at < bytes.len and std.mem.startsWith(u8, bytes[at..], "tagger "))) {
        // Early tags carry no tagger, which git reports only as information.
        if (try r.report(.missing_tagger_entry, "")) return true;
    } else {
        at += 7;
        if (try checkIdent(r, bytes, &at)) return true;
    }
    if (at < bytes.len and (std.mem.startsWith(u8, bytes[at..], "gpgsig ") or std.mem.startsWith(u8, bytes[at..], "gpgsig-sha256 "))) {
        const eol = std.mem.findScalarPos(u8, bytes, at, '\n') orelse return r.report(.bad_gpgsig, "");
        at = eol + 1;
        while (at < bytes.len and bytes[at] == ' ') {
            const cont = std.mem.findScalarPos(u8, bytes, at, '\n') orelse return r.report(.bad_header_continuation, "");
            at = cont + 1;
        }
    }
    if (at < bytes.len and bytes[at] != '\n') {
        if (try r.report(.extra_header_entry, "")) return true;
    }
    return false;
}

/// git's `fsck_ident`: `Name <email> <seconds> <±hhmm>` and a line break.
/// `at` moves past the line. Whether the problem found is an error.
fn checkIdent(r: *Reporter, bytes: []const u8, at: *usize) Allocator.Error!bool {
    var p = at.*;
    const nl = std.mem.findScalarPos(u8, bytes, @min(p, bytes.len), '\n') orelse bytes.len;
    at.* = @min(nl + 1, bytes.len);
    const end = bytes.len;

    if (byteAt(bytes, p) == '<') return r.report(.missing_name_before_email, "");
    while (true) : (p += 1) {
        if (p >= end or bytes[p] == '\n') return r.report(.missing_email, "");
        if (bytes[p] == '>') return r.report(.bad_name, "");
        if (bytes[p] == '<') break;
    }
    if (p == 0 or bytes[p - 1] != ' ') return r.report(.missing_space_before_email, "");
    p += 1;
    while (true) : (p += 1) {
        if (p >= end or bytes[p] == '<' or bytes[p] == '\n') return r.report(.bad_email, "");
        if (bytes[p] == '>') break;
    }
    p += 1;
    if (byteAt(bytes, p) != ' ') return r.report(.missing_space_before_date, "");
    p += 1;
    while (byteAt(bytes, p) == ' ' or byteAt(bytes, p) == '\t') p += 1;
    if (!std.ascii.isDigit(byteAt(bytes, p))) return r.report(.bad_date, "");
    if (byteAt(bytes, p) == '0' and byteAt(bytes, p + 1) != ' ') return r.report(.zero_padded_date, "");
    // git copies at most 23 digits, and more is past any date it keeps.
    const digits_start = p;
    var overflow = false;
    while (p < end and std.ascii.isDigit(bytes[p])) {
        if (p - digits_start >= 23) {
            overflow = true;
            break;
        }
        p += 1;
    }
    if (!overflow) {
        const seconds = std.fmt.parseInt(u64, bytes[digits_start..p], 10) catch std.math.maxInt(u64);
        overflow = seconds > std.math.maxInt(i64);
    }
    if (overflow) return r.report(.bad_date_overflow, "");
    if (byteAt(bytes, p) != ' ') return r.report(.bad_date, "");
    p += 1;
    if ((byteAt(bytes, p) != '+' and byteAt(bytes, p) != '-') or
        !std.ascii.isDigit(byteAt(bytes, p + 1)) or !std.ascii.isDigit(byteAt(bytes, p + 2)) or
        !std.ascii.isDigit(byteAt(bytes, p + 3)) or !std.ascii.isDigit(byteAt(bytes, p + 4)) or
        byteAt(bytes, p + 5) != '\n')
        return r.report(.bad_timezone, "");
    return false;
}

/// git's largest `.gitattributes` it reads, and its longest line.
const attr_max_file_size: usize = 100 * 1024 * 1024;
const attr_max_line_length: usize = 2048;

/// A special blob, or null content when it exceeds the read limit.
pub const BlobInputs = struct { oid: Oid, as: Special, bytes: ?[]const u8 };
pub const BlobOptions = struct { sink: ?Sink = null };

/// The first error in a blob a tree named `.gitmodules` or
/// `.gitattributes`, as git's `fsck_blob` finds it; `bytes` is `null` for
/// one too large to read.
pub fn checkBlob(gpa: Allocator, rules: *const Rules, inputs: BlobInputs, options: BlobOptions) Allocator.Error!?Finding {
    const oid = inputs.oid;
    const as = inputs.as;
    const bytes = inputs.bytes;
    const sink = options.sink;
    var r: Reporter = .{ .rules = rules, .oid = oid, .sink = sink };
    if (rules.skips(oid)) return null;
    switch (as) {
        .modules => {
            const content = bytes orelse {
                _ = try r.report(.gitmodules_large, "");
                return r.first;
            };
            var partial = try config_mod.Config.parseTextUntilError(gpa, content, .local);
            defer partial.config.deinit();
            const failed = partial.failure != null;
            for (partial.config.entries.items) |entry| {
                if (!entry.has_subsection or !std.mem.eql(u8, entry.section, "submodule")) continue;
                const name = entry.subsection;
                // git's parser stops at a value it cannot read, and so
                // does the partial parse: what is here was read.
                const value: ?[]const u8 = entry.value;
                if (!gitmodules.checkName(name)) _ = try r.report(.gitmodules_name, name);
                if (value) |v| {
                    if (std.mem.eql(u8, entry.name, "url") and !gitmodules.checkUrl(v)) _ = try r.report(.gitmodules_url, v);
                    if (std.mem.eql(u8, entry.name, "path") and v.len != 0 and v[0] == '-') _ = try r.report(.gitmodules_path, v);
                    if (std.mem.eql(u8, entry.name, "update") and v.len != 0 and v[0] == '!') _ = try r.report(.gitmodules_update, v);
                }
            }
            if (failed) _ = try r.report(.gitmodules_parse, "");
        },
        .attributes => {
            const content = bytes orelse {
                _ = try r.report(.gitattributes_large, "");
                return r.first;
            };
            if (content.len > attr_max_file_size) {
                _ = try r.report(.gitattributes_large, "");
                return r.first;
            }
            // git reads it as a C string: a NUL ends it.
            const text_ = content[0 .. std.mem.findScalar(u8, content, 0) orelse content.len];
            var lines = std.mem.splitScalar(u8, text_, '\n');
            while (lines.next()) |line| {
                if (line.len >= attr_max_line_length) {
                    _ = try r.report(.gitattributes_line_length, "");
                    break;
                }
            }
        },
    }
    return r.first;
}

/// A found blob that is not there, or is not a blob: git's
/// `gitmodulesMissing`, `gitmodulesBlob` and the `.gitattributes` pair.
pub fn checkFoundObject(rules: *const Rules, oid: Oid, as: Special, missing: bool, sink: ?Sink) Allocator.Error!?Finding {
    var r: Reporter = .{ .rules = rules, .oid = oid, .sink = sink };
    const problem: Problem = switch (as) {
        .modules => if (missing) .gitmodules_missing else .gitmodules_blob,
        .attributes => if (missing) .gitattributes_missing else .gitattributes_blob,
    };
    _ = try r.report(problem, "");
    return r.first;
}

const testing = std.testing;
const testgit = @import("../testing/git.zig");

const zero_hex = "0000000000000000000000000000000000000000";
const good_ident = "A U Thor <author@example.com> 1700000000 +0000";

/// The first problem `rules` makes an error of, by git's `fsck_object`.
fn firstProblem(rules: *const Rules, t: object.Type, bytes: []const u8) !?Problem {
    const finding = try checkObject(testing.allocator, rules, .{ .kind = .sha1, .oid = .zero(.sha1), .type = t, .bytes = bytes }, .{ .found = null, .sink = null }) orelse return null;
    return finding.problem;
}

fn baselineProblem(t: object.Type, bytes: []const u8) !?Problem {
    return firstProblem(&baseline, t, bytes);
}

test "a well-formed commit, tree and tag have no problem" {
    const commit = "tree " ++ zero_hex ++ "\nparent " ++ zero_hex ++ "\nauthor " ++ good_ident ++
        "\ncommitter " ++ good_ident ++ "\n\nmessage\n";
    try testing.expect(try baselineProblem(.commit, commit) == null);
    const tag = "object " ++ zero_hex ++ "\ntype commit\ntag v1\ntagger " ++ good_ident ++ "\n\nv1\n";
    try testing.expect(try baselineProblem(.tag, tag) == null);
    const tree = "100644 a.c\x00" ++ (&@as([20]u8, @splat(0x01))) ++ "40000 a\x00" ++ (&@as([20]u8, @splat(0x02))) ++ "100644 a0\x00" ++ (&@as([20]u8, @splat(0x03)));
    try testing.expect(try baselineProblem(.tree, tree) == null);
    try testing.expect(try baselineProblem(.tree, "") == null);
    try testing.expect(try baselineProblem(.blob, "\x00anything") == null);
}

test "each broken commit is named as git names it" {
    const Case = struct { bytes: []const u8, problem: Problem };
    const cases = [_]Case{
        .{ .bytes = "parent " ++ zero_hex ++ "\n", .problem = .missing_tree },
        .{ .bytes = "tree 123\n", .problem = .bad_tree_sha1 },
        .{ .bytes = "tree " ++ zero_hex ++ "\nparent xyz\n", .problem = .bad_parent_sha1 },
        .{ .bytes = "tree " ++ zero_hex ++ "\ncommitter " ++ good_ident ++ "\n", .problem = .missing_author },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor " ++ good_ident ++ "\nauthor " ++ good_ident ++ "\n", .problem = .multiple_authors },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor " ++ good_ident ++ "\n", .problem = .missing_committer },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor <a@b> 1 +0000\n", .problem = .missing_name_before_email },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A> <a@b> 1 +0000\n", .problem = .bad_name },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A 1 +0000\n", .problem = .missing_email },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A<a@b> 1 +0000\n", .problem = .missing_space_before_email },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b\n", .problem = .bad_email },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b>1 +0000\n", .problem = .missing_space_before_date },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 01 +0000\n", .problem = .zero_padded_date },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 99999999999999999999 +0000\n", .problem = .bad_date_overflow },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> x +0000\n", .problem = .bad_date },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 1 0000\n", .problem = .bad_timezone },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 1 +0000", .problem = .unterminated_header },
        .{ .bytes = "tree " ++ zero_hex ++ "\x00\n", .problem = .nul_in_header },
    };
    for (cases) |case| {
        try testing.expectEqual(@as(?Problem, case.problem), try baselineProblem(.commit, case.bytes));
    }
}

test "each broken tag is named as git names it" {
    const Case = struct { bytes: []const u8, problem: Problem };
    const cases = [_]Case{
        .{ .bytes = "type commit\n", .problem = .missing_object },
        .{ .bytes = "object 12\n", .problem = .bad_object_sha1 },
        .{ .bytes = "object " ++ zero_hex ++ "\ntag v1\n", .problem = .missing_type_entry },
        .{ .bytes = "object " ++ zero_hex ++ "\ntype bogus\ntag v1\n", .problem = .bad_type },
        .{ .bytes = "object " ++ zero_hex ++ "\ntype commit\ntagger " ++ good_ident ++ "\n", .problem = .missing_tag_entry },
        .{ .bytes = "object " ++ zero_hex ++ "\ntype commit\ntag v1\ntagger A <a@b> 1 +00\n", .problem = .bad_timezone },
    };
    for (cases) |case| {
        try testing.expectEqual(@as(?Problem, case.problem), try baselineProblem(.tag, case.bytes));
    }
    // A tag with no tagger is old, not broken.
    try testing.expect(try baselineProblem(.tag, "object " ++ zero_hex ++ "\ntype commit\ntag v1\n\nold\n") == null);
}

test "a tree out of order, with a twin, or naming .git is refused by name" {
    const oid = &@as([20]u8, @splat(0x01));
    try testing.expectEqual(@as(?Problem, .tree_not_sorted), try baselineProblem(.tree, "100644 b\x00" ++ oid ++ "100644 a\x00" ++ oid));
    try testing.expectEqual(@as(?Problem, .duplicate_entries), try baselineProblem(.tree, "100644 a\x00" ++ oid ++ "100644 a\x00" ++ oid));
    // The blob `a` and the tree `a` sort apart, with `a.c` between them.
    try testing.expectEqual(@as(?Problem, .duplicate_entries), try baselineProblem(.tree, "100644 a\x00" ++ oid ++ "100644 a.c\x00" ++ oid ++ "40000 a\x00" ++ oid));
    for ([_][]const u8{ ".git", ".GIT", "git~1", ".git. ", ".g\u{200c}it", ".git::$INDEX_ALLOCATION" }) |name| {
        var buf: [64]u8 = undefined;
        const tree = try std.mem.print(&buf, "40000 {s}\x00{s}", .{ name, oid });
        try testing.expectEqual(@as(?Problem, .has_dotgit), try baselineProblem(.tree, tree));
    }
    try testing.expectEqual(@as(?Problem, .has_dotdot), try baselineProblem(.tree, "40000 ..\x00" ++ oid));
    try testing.expectEqual(@as(?Problem, .has_dot), try baselineProblem(.tree, "40000 .\x00" ++ oid));
    try testing.expectEqual(@as(?Problem, .bad_tree), try baselineProblem(.tree, "100644 a\x00" ++ @as([3]u8, @splat(0x01))));
    try testing.expectEqual(@as(?Problem, .bad_tree), try baselineProblem(.tree, "999999 a\x00" ++ oid));
    // A style warning is not an error unless strict.
    const padded = "040000 a\x00" ++ oid;
    try testing.expect(try baselineProblem(.tree, padded) == null);
    const strict: Rules = .{ .strict = true };
    try testing.expectEqual(@as(?Problem, .zero_padded_filemode), try firstProblem(&strict, .tree, padded));
    // `100664` is information, an error only when raised.
    try testing.expect(try firstProblem(&strict, .tree, "100664 a\x00" ++ oid) == null);
}

test "the found .gitmodules and .gitattributes are read as git reads them" {
    const gpa = testing.allocator;
    var found: Found = .{};
    defer found.deinit(gpa);
    const a = &@as([20]u8, @splat('\n'));
    const m = &@as([20]u8, @splat(0x0b));
    const tree = "100644 .gitattributes\x00" ++ a ++ "100644 .gitmodules\x00" ++ m ++ "120000 .mailmap\x00" ++ m;
    var warnings: Collected = .{ .gpa = gpa };
    defer warnings.deinit();
    try testing.expect(try checkObject(gpa, &baseline, .{ .kind = .sha1, .oid = .zero(.sha1), .type = .tree, .bytes = tree }, .{ .found = &found, .sink = warnings.sink() }) == null);
    try testing.expect(found.modules.contains(try Oid.fromRaw(.sha1, m)));
    try testing.expect(found.attributes.contains(try Oid.fromRaw(.sha1, a)));
    // A symbolic `.mailmap` is information: a warning, never an error.
    try testing.expectEqual(@as(usize, 1), warnings.items.items.len);
    try testing.expectEqual(Problem.mailmap_symlink, warnings.items.items[0]);

    const strict: Rules = .{ .strict = true };
    const oid: Oid = .zero(.sha1);
    const Case = struct { text: []const u8, problem: ?Problem };
    for ([_]Case{
        .{ .text = "[submodule \"a\"]\n\tpath = a\n\turl = https://example.com/a\n", .problem = null },
        .{ .text = "[submodule \"../a\"]\n\tpath = a\n", .problem = .gitmodules_name },
        .{ .text = "[submodule \"a\"]\n\turl = -u/x\n", .problem = .gitmodules_url },
        .{ .text = "[submodule \"a\"]\n\tpath = -a\n", .problem = .gitmodules_path },
        .{ .text = "[submodule \"a\"]\n\tupdate = !rm -rf /\n", .problem = .gitmodules_update },
        // What comes before a parse error is still read.
        .{ .text = "[submodule \"a\"]\n\turl = -u/x\n[broken\n", .problem = .gitmodules_url },
    }) |case| {
        const finding = try checkBlob(gpa, &strict, .{ .oid = oid, .as = .modules, .bytes = case.text }, .{ .sink = null });
        try testing.expectEqual(case.problem, if (finding) |f| f.problem else null);
    }
    // An unparsable file is information.
    try testing.expect(try checkBlob(gpa, &strict, .{ .oid = oid, .as = .modules, .bytes = "[broken\n" }, .{ .sink = null }) == null);
    const long = @as([2048]u8, @splat('a')) ++ " text\n";
    try testing.expectEqual(@as(?Problem, .gitattributes_line_length), (try checkBlob(gpa, &strict, .{ .oid = oid, .as = .attributes, .bytes = long }, .{ .sink = null })).?.problem);
    try testing.expect(try checkBlob(gpa, &strict, .{ .oid = oid, .as = .attributes, .bytes = "*.c text\n" }, .{ .sink = null }) == null);
}

const Collected = struct {
    gpa: Allocator,
    items: std.ArrayList(Problem) = .empty,
    unknown: std.ArrayList([]const u8) = .empty,

    fn deinit(c: *Collected) void {
        c.items.deinit(c.gpa);
        for (c.unknown.items) |name| c.gpa.free(name);
        c.unknown.deinit(c.gpa);
        c.* = undefined;
    }

    fn sink(c: *Collected) Sink {
        return .{ .context = c, .warning = noteProblem, .unknown = unknownName };
    }

    fn noteProblem(context: *anyopaque, finding: Finding) Allocator.Error!void {
        const c: *Collected = @ptrCast(@alignCast(context)); // safe: the context is the Collected the sink was made from
        try c.items.append(c.gpa, finding.problem.?);
    }

    fn unknownName(context: *anyopaque, name: []const u8) Allocator.Error!void {
        const c: *Collected = @ptrCast(@alignCast(context)); // safe: the context is the Collected the sink was made from
        try c.unknown.append(c.gpa, try c.gpa.dupe(u8, name));
    }
};

test "levels and skip lists come from the scope's own settings" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const skipped = "1111111111111111111111111111111111111111";
    try tmp.dir.writeFile(io, .{ .sub_path = "skip", .data = "# known broken\n  " ++ skipped ++ "  # old import\r\n\n" });
    const skip_path = try tmp.dir.realPathFileAlloc(io, "skip", gpa);
    defer gpa.free(skip_path);
    // A backslash would be an escape in the configuration.
    std.mem.replaceScalar(u8, skip_path, '\\', '/');
    const text = try gpa.print(
        \\[fsck]
        \\    missingEmail = ignore
        \\[fetch "fsck"]
        \\    badTimezone = warn
        \\    noSuchMessage = ignore
        \\    zeroPaddedFilemode = ignore
        \\    skipList = {s}
        \\
    , .{skip_path});
    defer gpa.free(text);
    var config = try config_mod.Config.parseText(gpa, text, .local);
    defer config.deinit();

    var collected: Collected = .{ .gpa = gpa };
    defer collected.deinit();
    var rules = try Rules.load(gpa, io, &config, .{ .kind = .sha1, .scope = .fetch, .strict = true, .sink = collected.sink() });
    defer rules.deinit(gpa);
    try testing.expectEqual(Level.warn, rules.level(.bad_timezone));
    try testing.expectEqual(Level.ignore, rules.level(.zero_padded_filemode));
    // `fsck.` does not reach a fetch, and strict raises the warnings.
    try testing.expectEqual(Level.@"error", rules.level(.missing_email));
    try testing.expectEqual(Level.@"error", rules.level(.null_sha1));
    try testing.expectEqual(Level.info, rules.level(.bad_filemode));
    try testing.expectEqual(@as(usize, 1), collected.unknown.items.len);
    try testing.expectEqualStrings("nosuchmessage", collected.unknown.items[0]);
    try testing.expect(rules.skips(try Oid.parse(.sha1, skipped)));

    // A skipped object is not reported, and a lowered one only warns.
    const bad_tz = "tree " ++ zero_hex ++ "\nauthor A <a@b> 1 0000\ncommitter " ++ good_ident ++ "\n\n";
    try testing.expect(try checkObject(gpa, &rules, .{ .kind = .sha1, .oid = try Oid.parse(.sha1, skipped), .type = .commit, .bytes = "tree 1\n" }, .{ .found = null, .sink = null }) == null);
    try testing.expect(try checkObject(gpa, &rules, .{ .kind = .sha1, .oid = .zero(.sha1), .type = .commit, .bytes = bad_tz }, .{ .found = null, .sink = collected.sink() }) == null);
    try testing.expectEqual(Problem.bad_timezone, collected.items.items[0]);

    // git's own `fsck.` refuses a name it does not know, and lowering a
    // fatal problem.
    var fsck_config = try config_mod.Config.parseText(gpa, "[fsck]\n\tnoSuchMessage = ignore\n", .local);
    defer fsck_config.deinit();
    try testing.expectError(error.UnknownFsckMessage, Rules.load(gpa, io, &fsck_config, .{ .kind = .sha1 }));
    var r: Rules = .{};
    try testing.expectError(error.FsckFatalLowered, r.set("nulinheader", "warn"));
    try r.set("nulinheader", "error");
    try testing.expectError(error.UnknownFsckLevel, r.set("baddate", "loud"));
    try r.set("largepathname", "error:10");
    try testing.expectEqual(@as(usize, 10), r.max_entry_len);
}

test "fetch.fsckObjects falls back on transfer.fsckObjects" {
    const gpa = testing.allocator;
    var none = try config_mod.Config.parseText(gpa, "", .local);
    defer none.deinit();
    try testing.expectEqual(@as(?bool, null), try wanted(&none, .fetch));
    var transfer = try config_mod.Config.parseText(gpa, "[transfer]\n\tfsckObjects = true\n[receive]\n\tfsckObjects = false\n", .local);
    defer transfer.deinit();
    try testing.expectEqual(@as(?bool, true), try wanted(&transfer, .fetch));
    try testing.expectEqual(@as(?bool, false), try wanted(&transfer, .receive));
}

test "every message id is git's" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    // `git help --config` lists every `fsck.<msg-id>` git knows.
    const out = try repo.run(io, &.{ "help", "--config" });
    defer gpa.free(out);
    var listed: usize = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "fsck.")) continue;
        const name = line["fsck.".len..];
        if (std.ascii.eqlIgnoreCase(name, "skipList")) continue;
        const problem = Problem.fromConfigName(name) orelse {
            std.debug.print("git knows fsck.{s}\n", .{name});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(name, problem.id());
        listed += 1;
    }
    // The ids about refs came with later versions; this one's are all.
    if (try testgit.gitAtLeast(gpa, io, 2, 55)) try testing.expectEqual(@as(usize, Problem.count), listed);
}

test "git refuses the same objects and names the same problem" {
    const gpa = testing.allocator;
    const io = testing.io;
    // git before 2.40 dies on some of these objects rather than name the problem.
    try testgit.requireGitVersion(gpa, io, 2, 40);
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    const Case = struct { t: object.Type, bytes: []const u8, problem: Problem };
    const oid = &@as([20]u8, @splat(0x01));
    const cases = [_]Case{
        .{ .t = .commit, .bytes = "tree 123\nauthor " ++ good_ident ++ "\n", .problem = .bad_tree_sha1 },
        .{ .t = .commit, .bytes = "tree " ++ zero_hex ++ "\nauthor " ++ good_ident ++ "\n\n", .problem = .missing_committer },
        .{ .t = .commit, .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 01 +0000\ncommitter " ++ good_ident ++ "\n\n", .problem = .zero_padded_date },
        .{ .t = .commit, .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 1 +00\ncommitter " ++ good_ident ++ "\n\n", .problem = .bad_timezone },
        .{ .t = .tag, .bytes = "object " ++ zero_hex ++ "\ntype bogus\ntag v1\n\n", .problem = .bad_type },
        .{ .t = .tag, .bytes = "object " ++ zero_hex ++ "\ntype commit\n\n", .problem = .missing_tag_entry },
        .{ .t = .tree, .bytes = "100644 b\x00" ++ oid ++ "100644 a\x00" ++ oid, .problem = .tree_not_sorted },
        .{ .t = .tree, .bytes = "100644 a\x00" ++ oid ++ "100644 a\x00" ++ oid, .problem = .duplicate_entries },
        .{ .t = .tree, .bytes = "40000 .git\x00" ++ oid, .problem = .has_dotgit },
    };
    for (cases) |case| {
        try testing.expectEqual(@as(?Problem, case.problem), try baselineProblem(case.t, case.bytes));
        // `hash-object` without `--literally` runs git's fsck checks and
        // refuses, naming the message id on standard error.
        try repo.writeFile(io, "object", case.bytes);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, testgit.program());
        try argv.appendSlice(gpa, repo.defaults);
        try argv.appendSlice(gpa, &.{ "hash-object", "-t", case.t.name(), "object" });
        const result = try std.process.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .dir = repo.dir }, .environ_map = repo.environMap() });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try testing.expect(result.term != .exited or result.term.exited != 0);
        if (std.mem.find(u8, result.stderr, case.problem.id()) == null) {
            std.debug.print("git said: {s}\nexpected: {s}\n", .{ result.stderr, case.problem.id() });
            return error.TestUnexpectedResult;
        }
    }
}

test "fuzz: any bytes are a verdict, never a crash" {
    try shakedown.check(testing.allocator, {}, fuzzCheck, .{});
}

fn fuzzCheck(_: void, case: *shakedown.Case) anyerror!void {
    var scratch: [1024]u8 = undefined;
    const input = scratch[0..shakedown.gen.intRange(case.source, usize, 0, scratch.len)];
    case.source.bytes(input);
    const strict: Rules = .{ .strict = true };
    for ([_]object.Type{ .blob, .tree, .commit, .tag }) |t| {
        for ([_]Kind{ .sha1, .sha256 }) |kind| {
            var found: Found = .{};
            defer found.deinit(testing.allocator);
            _ = try inspect(testing.allocator, &strict, .{ .kind = kind, .oid = .zero(kind), .type = t, .bytes = input }, .{ .found = &found, .sink = null });
        }
    }
    _ = try checkBlob(testing.allocator, &strict, .{ .oid = .zero(.sha1), .as = .modules, .bytes = input }, .{ .sink = null });
    _ = try checkBlob(testing.allocator, &strict, .{ .oid = .zero(.sha1), .as = .attributes, .bytes = input }, .{ .sink = null });
}

/// All errors reported by this namespace.
pub const Error = LoadError || ForTransferError || config_mod.ValueError || Allocator.Error;
