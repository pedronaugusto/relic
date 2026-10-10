//! git's `ref-filter`: what `git for-each-ref`, `git branch --list` and
//! `git tag --list` select, sort and print.
//!
//! A `Listing` gathers the refs a `Filter` lets through — by kind, by
//! pattern (`for-each-ref`'s path prefixes, or the globs `branch` and `tag`
//! match after `refs/heads/` and the rest), `--exclude`, `--points-at`,
//! `--contains`, `--no-contains`, `--merged`, `--no-merged` and
//! `--start-after` — sorts them by any `--sort` key, version sort and
//! `versionsort.suffix` included, and formats each with git's `%(...)`
//! atoms: names and their `short`, `lstrip` and `rstrip` forms, object
//! names, types, sizes and delta bases, the fields of commits and tags, the
//! mailmap's people, dates in every mode, subjects, bodies, signatures and
//! raw contents, `describe`, upstream and push tracking, worktrees, `HEAD`,
//! `ahead-behind` and `is-base`, and the `align` and `if` blocks, under
//! any of git's four quoting styles.
//!
//! Colour is off, as git's is when it is not writing to a terminal: a
//! `%(color:...)` git accepts writes nothing. Trailers are read as the
//! repository's `trailer.*` settings say.

const ErrorNamespace = @This();
const unicodewidth = @import("../text.zig").unicodewidth;
const builtin = @import("builtin");
const std = @import("std");
const percent = @import("../text.zig").percent;
const revparse_mod = @import("../revwalk/revparse.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const refs_mod = @import("../refs/refs.zig");
const ref_names = @import("../names.zig").ref;
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const revwalk = @import("../walk/walk.zig");
const describe_mod = @import("../revwalk/describe.zig");
const mailmap_mod = @import("../revwalk/mailmap.zig");
const abbrev_mod = @import("../odb/abbrev.zig");
const signing = @import("../object/signing.zig");
const gitdate = @import("../text.zig").date;
const glob_mod = @import("../text.zig").glob;
const worktrees = @import("../checkout/worktrees.zig");
const remote_mod = @import("../wire.zig").remote;
const refspec = @import("../wire.zig").refspec;
const pretty = @import("pretty.zig");
const trailer = @import("../object/trailer.zig");
const message = @import("../object/message.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from listing and formatting refs.
pub const Error = errors: {
    break :errors error{
        /// `%(...)` naming no atom git has: "unknown field name".
        UnknownField,
        /// A `%(` with no `)`, or `%(*)`: "malformed format string".
        MalformedFormat,
        /// An atom's argument git does not take: "unrecognized argument", "does
        /// not take arguments", "expected format", a bad width or position.
        BadFieldArgument,
        /// `%(then)`, `%(else)` or `%(end)` out of place, or a block left open.
        UnbalancedBlock,
        /// `%(raw)` under `--shell`, `--python` or `--tcl`.
        RawNeedsBinarySafeQuote,
        /// `%(rest)`, which only `cat-file` has.
        RejectedField,
        /// A ref names an object the repository does not have: "missing object".
        MissingObject,
        /// A tag that does not peel: "bad tag".
        BadTag,
        /// `%(ahead-behind:<rev>)` or `%(is-base:<rev>)` naming no commit:
        /// "failed to find".
        UnknownCommit,
        /// A date mode git does not know.
        UnknownDateFormat,
        /// A `relative` or `human` date, or a `-local` one, with no clock or
        /// zone in the `Context`.
        DateNeedsClock,
        /// A signature atom for a signed commit, with no `signer`.
        SignatureNeedsSigner,
    } || Allocator.Error || refs_mod.ReadError || odb_mod.Error || object.ParseError ||
        revwalk.Error || signing.Error || remote_mod.Error || worktrees.Error || mailmap_mod.LoadError || describe_mod.Error;
};

/// The kinds of ref a listing takes: git's `FILTER_REFS_*`.
pub const Kinds = packed struct {
    /// `refs/heads/`.
    branches: bool = false,
    /// `refs/remotes/`.
    remotes: bool = false,
    /// `refs/tags/`.
    tags: bool = false,
    /// Every other ref under `refs/`.
    others: bool = false,
    /// `HEAD`, when it is detached: what `git branch --list` adds.
    detached_head: bool = false,
    /// `HEAD` and the other root refs (`ORIG_HEAD`, `CHERRY_PICK_HEAD`,
    /// ...), as `--include-root-refs` asks.
    root_refs: bool = false,

    /// Every ref under `refs/`: what `for-each-ref` lists.
    pub const regular: Kinds = .{ .branches = true, .remotes = true, .tags = true, .others = true };

    fn any(k: Kinds, other: Kinds) bool {
        return (k.branches and other.branches) or (k.remotes and other.remotes) or (k.tags and other.tags) or
            (k.others and other.others) or (k.detached_head and other.detached_head) or (k.root_refs and other.root_refs);
    }

    fn onlyOne(k: Kinds) ?Kind {
        const as_int: u6 = @bitCast(k);
        if (as_int == @as(u6, @bitCast(Kinds{ .branches = true }))) return .branch;
        if (as_int == @as(u6, @bitCast(Kinds{ .remotes = true }))) return .remote;
        if (as_int == @as(u6, @bitCast(Kinds{ .tags = true }))) return .tag;
        return null;
    }
};

/// What one ref is: git's `ref_kind_from_refname`.
pub const Kind = enum {
    branch,
    remote,
    tag,
    other,
    detached_head,
    pseudo_ref,
    root_ref,

    /// The kind of the ref named `name`.
    pub fn of(name: []const u8) Kind {
        if (std.mem.eql(u8, name, "HEAD")) return .detached_head;
        if (std.mem.startsWith(u8, name, "refs/heads/")) return .branch;
        if (std.mem.startsWith(u8, name, "refs/remotes/")) return .remote;
        if (std.mem.startsWith(u8, name, "refs/tags/")) return .tag;
        if (ref_names.isSpecial(name)) return .pseudo_ref;
        if (ref_names.isRootRef(name)) return .root_ref;
        return .other;
    }

    fn in(k: Kind, kinds: Kinds) bool {
        return switch (k) {
            .branch => kinds.branches,
            .remote => kinds.remotes,
            .tag => kinds.tags,
            .other => kinds.others,
            .detached_head => kinds.detached_head,
            .pseudo_ref => false,
            .root_ref => kinds.root_refs,
        };
    }
};

/// Which refs a listing takes: git's `struct ref_filter`.
pub const Filter = struct {
    kinds: Kinds = .regular,
    /// The patterns a ref must match one of; none matches every ref.
    patterns: []const []const u8 = &.{},
    /// How patterns match: `for-each-ref`'s way (a prefix ending at a `/`,
    /// or a glob over the whole name with `/` special), or, when false, the
    /// way of `branch` and `tag` (a glob over the name less `refs/heads/`,
    /// `refs/tags/`, `refs/remotes/` or `refs/`).
    match_as_path: bool = true,
    /// `--ignore-case`, for the patterns.
    ignore_case: bool = false,
    /// `--exclude`: refs matching one of these, the same way, are left out.
    exclude: []const []const u8 = &.{},
    /// `--points-at`: refs naming one of these, directly or through tags.
    points_at: []const Oid = &.{},
    /// `--contains`: refs whose commit reaches one of these.
    contains: []const Oid = &.{},
    /// `--no-contains`: refs whose commit reaches none of these.
    no_contains: []const Oid = &.{},
    /// `--merged`: refs whose commit one of these reaches.
    merged: []const Oid = &.{},
    /// `--no-merged`: refs whose commit none of these reaches.
    no_merged: []const Oid = &.{},
    /// Only refs that peel to a commit: what `git branch -v` lists.
    commits_only: bool = false,
    /// `--start-after`: only refs that sort after this name.
    start_after: ?[]const u8 = null,
};

/// How a value is quoted: `--shell`, `--perl`, `--python`, `--tcl`.
pub const Quote = enum { none, shell, perl, python, tcl };

/// What a listing may need beyond the repository.
pub const Context = struct {
    /// What checks signatures for `%(signature...)`. A commit with none
    /// needs none.
    signer: ?*signing.Signer = null,
    /// The time now and the local zone, for `relative`, `human` and
    /// `-local` dates.
    clock: gitdate.Clock = .{},
};

/// One `--sort` key.
pub const SortKey = struct {
    /// The atom, as written after `-` and `version:`: `refname`,
    /// `-creatordate` is `.{ .atom = "creatordate", .reverse = true }`.
    atom: []const u8,
    reverse: bool = false,
    /// `version:` or `v:`: git's version sort.
    version: bool = false,

    /// A key as `--sort=<key>` spells it.
    pub fn parse(text: []const u8) SortKey {
        var key: SortKey = .{ .atom = text };
        if (key.atom.len > 0 and key.atom[0] == '-') {
            key.reverse = true;
            key.atom = key.atom[1..];
        }
        for ([_][]const u8{ "version:", "v:" }) |prefix| {
            if (std.mem.startsWith(u8, key.atom, prefix)) {
                key.version = true;
                key.atom = key.atom[prefix.len..];
                break;
            }
        }
        return key;
    }
};

/// How sorting compares: git's `REF_SORTING_*` flags that apply to every
/// key.
pub const SortOptions = struct {
    /// `--ignore-case`.
    ignore_case: bool = false,
    /// A detached `HEAD` first, whatever the keys say: what `git branch`
    /// asks.
    detached_head_first: bool = false,
};

/// The keys a command sorts by when none is given: `branch.sort` or
/// `tag.sort`'s values, each a `--sort` key, else `refname`. The keys
/// borrow `config`; the slice is the caller's. As on git's command line,
/// the last key is the first one sorted by.
pub fn configuredSort(gpa: Allocator, config: *const config_mod.Config, name: []const u8) Allocator.Error![]SortKey {
    const values = try config.all(name);
    defer config.gpa.free(values);
    var keys: std.ArrayList(SortKey) = .empty;
    errdefer keys.deinit(gpa);
    for (values) |value| try keys.append(gpa, .parse(value));
    if (keys.items.len == 0) try keys.append(gpa, .{ .atom = "refname" });
    return keys.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// versioncmp
// ---------------------------------------------------------------------------

const s_n = 0x0;
const s_i = 0x3;
const s_f = 0x6;
const s_z = 0x9;
const cmp = 2;
const compare_length = 3;

fn charAt(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

fn digitClass(c: u8) u8 {
    return @as(u8, @intFromBool(c == '0')) + @intFromBool(std.ascii.isDigit(c));
}

const SuffixMatch = struct { conf_pos: i32, start: usize, len: i64 };

fn betterSuffix(tag: []const u8, suffix: []const u8, start: usize, conf_pos: i32, match: *SuffixMatch) void {
    const suffix_len: i64 = @intCast(suffix.len);
    const end: i64 = if (match.len < suffix_len) @intCast(match.start) else @as(i64, @intCast(match.start)) - 1;
    var i: i64 = @intCast(start);
    while (i <= end) : (i += 1) {
        const at: usize = @intCast(i);
        if (at <= tag.len and std.mem.startsWith(u8, tag[at..], suffix)) {
            match.* = .{ .conf_pos = conf_pos, .start = at, .len = suffix_len };
            break;
        }
    }
}

fn swapPrereleases(s1: []const u8, s2: []const u8, off: usize, prereleases: []const []const u8) ?i32 {
    var m1: SuffixMatch = .{ .conf_pos = -1, .start = off, .len = -1 };
    var m2: SuffixMatch = .{ .conf_pos = -1, .start = off, .len = -1 };
    for (prereleases, 0..) |suffix, i| {
        const start: usize = if (suffix.len < off) off - suffix.len else 0;
        betterSuffix(s1, suffix, start, @intCast(i), &m1);
        betterSuffix(s2, suffix, start, @intCast(i), &m2);
    }
    if (m1.conf_pos == -1 and m2.conf_pos == -1) return null;
    if (m1.conf_pos == m2.conf_pos) return null;
    if (m1.conf_pos >= 0 and m2.conf_pos >= 0) return m1.conf_pos - m2.conf_pos;
    if (m1.conf_pos >= 0) return -1;
    return 1;
}

/// git's `versioncmp`, glibc's `strverscmp` with `versionsort.suffix`'s
/// prerelease suffixes, given as `prereleases`, sorting before the release
/// they precede.
pub fn versioncmp(s1: []const u8, s2: []const u8, prereleases: []const []const u8) i32 {
    const next_state = [_]u8{
        s_n, s_i, s_z,
        s_n, s_i, s_i,
        s_n, s_f, s_f,
        s_n, s_f, s_z,
    };
    const result_type = [_]i8{
        cmp, cmp, cmp, cmp, compare_length, cmp,            cmp, cmp,            cmp,
        cmp, -1,  -1,  1,   compare_length, compare_length, 1,   compare_length, compare_length,
        cmp, cmp, cmp, cmp, cmp,            cmp,            cmp, cmp,            cmp,
        cmp, 1,   1,   -1,  cmp,            cmp,            -1,  cmp,            cmp,
    };
    var p1: usize = 0;
    var p2: usize = 0;
    var c1 = charAt(s1, p1);
    var c2 = charAt(s2, p2);
    p1 += 1;
    p2 += 1;
    var state: u8 = s_n + digitClass(c1);
    var diff: i32 = @as(i32, c1) - @as(i32, c2);
    while (diff == 0) {
        if (c1 == 0) return 0;
        state = next_state[state];
        c1 = charAt(s1, p1);
        c2 = charAt(s2, p2);
        p1 += 1;
        p2 += 1;
        state += digitClass(c1);
        diff = @as(i32, c1) - @as(i32, c2);
    }
    if (prereleases.len != 0) {
        if (swapPrereleases(s1, s2, p1 - 1, prereleases)) |swapped| return swapped;
    }
    const kind = result_type[@as(usize, state) * 3 + digitClass(c2)];
    switch (kind) {
        cmp => return diff,
        compare_length => {
            while (true) {
                const d1 = std.ascii.isDigit(charAt(s1, p1));
                p1 += 1;
                if (!d1) break;
                const d2 = std.ascii.isDigit(charAt(s2, p2));
                p2 += 1;
                if (!d2) return 1;
            }
            return if (std.ascii.isDigit(charAt(s2, p2))) -1 else diff;
        },
        else => return kind,
    }
}

/// The prerelease suffixes `versioncmp` takes from a repository:
/// `versionsort.suffix`, or the older `versionsort.prereleaseSuffix` when
/// that is not set. The slice is the caller's; the names borrow `config`.
pub fn prereleaseSuffixes(gpa: Allocator, config: *const config_mod.Config) Allocator.Error![][]const u8 {
    const values = try config.all("versionsort.suffix");
    if (values.len != 0) {
        defer config.gpa.free(values);
        return gpa.dupe([]const u8, values);
    }
    config.gpa.free(values);
    const old = try config.all("versionsort.prereleasesuffix");
    defer config.gpa.free(old);
    return gpa.dupe([]const u8, old);
}

// ---------------------------------------------------------------------------
// atoms
// ---------------------------------------------------------------------------

const AtomKind = enum {
    refname,
    objecttype,
    objectsize,
    objectname,
    deltabase,
    tree,
    parent,
    numparent,
    object,
    type,
    tag,
    author,
    authorname,
    authoremail,
    authordate,
    committer,
    committername,
    committeremail,
    committerdate,
    tagger,
    taggername,
    taggeremail,
    taggerdate,
    creator,
    creatordate,
    describe,
    subject,
    body,
    trailers,
    contents,
    signature,
    raw,
    upstream,
    push,
    symref,
    flag,
    HEAD,
    color,
    worktreepath,
    @"align",
    end,
    @"if",
    then,
    @"else",
    rest,
    @"ahead-behind",
    @"is-base",
};

const Source = enum { none, obj, other };
const FieldType = enum { str, ulong, time };

fn sourceOf(kind: AtomKind) Source {
    return switch (kind) {
        .objecttype, .objectsize, .objectname, .deltabase, .@"ahead-behind", .@"is-base" => .other,
        .refname, .upstream, .push, .symref, .flag, .HEAD, .color, .worktreepath, .@"align", .end, .@"if", .then, .@"else", .rest => .none,
        else => .obj,
    };
}

fn fieldTypeOf(kind: AtomKind) FieldType {
    return switch (kind) {
        .objectsize, .numparent => .ulong,
        .authordate, .committerdate, .taggerdate, .creatordate => .time,
        else => .str,
    };
}

const RefnameOption = union(enum) { normal, short, lstrip: i32, rstrip: i32 };
const RemoteOption = enum { ref, track, trackshort, remotename, remoteref };
const ContentsOption = enum { bare, body, body_dep, length, lines, sig, sub, sub_sanitize, trailers };
const OidOption = union(enum) { full, short, length: u32 };
const Align = struct { position: enum { left, middle, right }, width: u32 };
const Compare = enum { none, equal, unequal };

const Atom = struct {
    kind: AtomKind,
    /// The whole text between `%(` and `)`, `*` included.
    name: []const u8,
    deref: bool,
    field: FieldType,
    refname: RefnameOption = .normal,
    remote: RemoteOption = .ref,
    nobracket: bool = false,
    push_remote: bool = false,
    contents: ContentsOption = .bare,
    lines: u32 = 0,
    raw_length: bool = false,
    oid: OidOption = .full,
    size_disk: bool = false,
    name_mailmap: bool = false,
    email_trim: bool = false,
    email_localpart: bool = false,
    email_mailmap: bool = false,
    signature: SignatureOption = .bare,
    @"align": Align = .{ .position = .left, .width = 0 },
    compare: Compare = .none,
    compare_with: []const u8 = "",
    describe: describe_mod.Options = .{},
    /// `ahead-behind` and `is-base`: the commit and the name it was given.
    base: ?Oid = null,
    base_name: []const u8 = "",
    head: ?[]const u8 = null,
    date: ?gitdate.Mode = null,
    trailers: trailer.Options = .{ .no_divider = true },
};

const SignatureOption = enum { bare, grade, signer, key, fingerprint, primarykeyfingerprint, trustlevel };

fn parseSignatureOption(arg: ?[]const u8) ?SignatureOption {
    const text = arg orelse return .bare;
    inline for (.{ "signer", "grade", "key", "fingerprint", "primarykeyfingerprint", "trustlevel" }) |name| {
        if (std.mem.eql(u8, text, name)) return @field(SignatureOption, name);
    }
    return null;
}

/// git's `trailers_atom_parser`: no divider, and the options of
/// `%(trailers:...)` as `%(trailers)` in a log format takes them.
fn parseTrailerOptions(arena: Allocator, arg: ?[]const u8) Error!trailer.Options {
    const text = arg orelse return .{ .no_divider = true };
    const with_paren = try std.mem.concat(arena, u8, &.{ text, ")" });
    const parsed = (try trailer.parsePlaceholderOptions(arena, with_paren)) orelse return error.BadFieldArgument;
    if (parsed.len != text.len) return error.BadFieldArgument;
    var options = parsed.options;
    options.no_divider = true;
    return options;
}

fn parseUnsigned(text: []const u8) ?u32 {
    // git's `strtoul_ui`: digits only, no sign, fits an int
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseUnsigned(u32, text, 10) catch null;
}

fn parseSigned(text: []const u8) ?i32 {
    // git's `strtol_i`
    if (text.len == 0) return null;
    return std.fmt.parseInt(i32, text, 10) catch null;
}

fn parseRefnameOption(arg: ?[]const u8) Error!RefnameOption {
    const text = arg orelse return .normal;
    if (std.mem.eql(u8, text, "short")) return .short;
    for ([_][]const u8{ "lstrip=", "strip=" }) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return .{ .lstrip = parseSigned(text[prefix.len..]) orelse return error.BadFieldArgument };
    }
    if (std.mem.startsWith(u8, text, "rstrip=")) return .{ .rstrip = parseSigned(text["rstrip=".len..]) orelse return error.BadFieldArgument };
    return error.BadFieldArgument;
}

/// git's `match_atom_arg_value`: `candidate`, `candidate=value`, then `,`
/// or the end. Returns the value (`null` without `=`) and the rest.
fn matchArgValue(text: []const u8, candidate: []const u8) ?struct { value: ?[]const u8, rest: []const u8 } {
    if (!std.mem.startsWith(u8, text, candidate)) return null;
    var at = candidate.len;
    var value: ?[]const u8 = null;
    if (at < text.len and text[at] == '=') {
        const start = at + 1;
        at = std.mem.findScalarPos(u8, text, start, ',') orelse text.len;
        value = text[start..at];
    } else if (at < text.len and text[at] != ',') return null;
    if (at < text.len and text[at] == ',') at += 1;
    return .{ .value = value, .rest = text[at..] };
}

fn maybeBool(text: []const u8) ?bool {
    return config_mod.parseBool(text) catch null;
}

// ---------------------------------------------------------------------------
// colours
// ---------------------------------------------------------------------------

/// Whether git's `color_parse` takes `value`: colour names, numbers, `#rgb`
/// and `#rrggbb`, attributes and their `no` forms, at most two colours.
fn validColor(value: []const u8) bool {
    if (value.len == 0) return true;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "reset")) return true;
    var colours: u8 = 0;
    var words = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (words.next()) |word| {
        if (isColour(word)) {
            colours += 1;
            if (colours > 2) return false;
            continue;
        }
        if (isAttribute(word)) continue;
        return false;
    }
    return true;
}

fn isColour(word: []const u8) bool {
    const names = [_][]const u8{ "normal", "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "default" };
    for (names) |name| if (std.ascii.eqlIgnoreCase(word, name)) return true;
    if (word.len > 6 and std.ascii.eqlIgnoreCase(word[0..6], "bright")) {
        for (names[1..9]) |name| if (std.ascii.eqlIgnoreCase(word[6..], name)) return true;
    }
    if (word.len > 0 and word[0] == '#') {
        if (word.len != 7 and word.len != 4) return false;
        for (word[1..]) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
    // a number from -1 to 255
    const n = std.fmt.parseInt(i32, word, 10) catch return false;
    return n >= -1 and n <= 255;
}

fn isAttribute(word_in: []const u8) bool {
    var word = word_in;
    if (std.ascii.startsWithIgnoreCase(word, "no")) {
        word = word[2..];
        if (word.len > 0 and word[0] == '-') word = word[1..];
    }
    for ([_][]const u8{ "bold", "dim", "italic", "ul", "blink", "reverse", "strike" }) |name| {
        if (std.ascii.eqlIgnoreCase(word, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// the listing
// ---------------------------------------------------------------------------

const CommitNode = struct { parents: []const Oid, date: i64 };

/// A remote a branch names, and whether its configuration named it.
const RemoteChoice = struct { name: []const u8, explicit: bool };

/// An atom's value for one ref.
const Value = struct {
    s: []const u8 = "",
    /// Whether `s` may hold a NUL: `%(raw)`, which is compared and quoted by
    /// its length rather than as a C string.
    sized: bool = false,
    num: u64 = 0,
    handler: Handler = .append,
};

const Handler = enum { append, @"align", end, @"if", then, @"else" };

/// An object a value is read from.
const ObjectData = struct {
    oid: Oid,
    type: object.Type,
    bytes: []const u8,
};

/// One ref a listing holds.
pub const Item = struct {
    /// The ref's full name, or `HEAD`.
    name: []const u8,
    /// The object it resolves to.
    oid: Oid,
    /// What it peels to, when `packed-refs` said.
    peeled: ?Oid = null,
    /// What a symbolic ref names, one step.
    symref: ?[]const u8 = null,
    is_symref: bool = false,
    is_packed: bool = false,
    kind: Kind,
    /// The commit it peels to, when a filter needed one.
    commit: ?Oid = null,
    values: std.ArrayList(?Value) = .empty,
    counts: ?[]?[2]usize = null,
    is_base: ?[]?[]const u8 = null,
    object: ?ObjectData = null,
    deref: ?ObjectData = null,
    deref_done: bool = false,
};

/// A compiled `--format`.
pub const Format = struct {
    parts: []const Part,
    quote: Quote,

    const Part = union(enum) {
        literal: []const u8,
        atom: usize,
    };
};

/// Refs gathered by a filter, sorted and formatted: git's `ref_array` and
/// the atoms its format and sort keys use.
pub const Listing = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    io: Io,
    repo: *Repository,
    context: Context,
    items: std.ArrayList(*Item) = .empty,
    atoms: std.ArrayList(Atom) = .empty,
    sort_keys: []const SortKey = &.{},
    sort_atoms: []const usize = &.{},
    sort_options: SortOptions = .{},
    prereleases: ?[]const []const u8 = null,
    mailmap: ?mailmap_mod.Mailmap = null,
    worktree_map: ?std.StringHashMapUnmanaged([]const u8) = null,
    describers: std.ArrayList(?*describe_mod.Describer) = .empty,
    commits: Oid.Map(CommitNode) = .empty,
    head_description: ?[]const u8 = null,
    trailer_settings: ?trailer.Settings = null,

    /// An empty listing over `repo`.
    pub fn init(gpa: Allocator, io: Io, repo: *Repository, context: Context) Listing {
        return .{ .gpa = gpa, .arena = .init(gpa), .io = io, .repo = repo, .context = context };
    }

    /// Release everything.
    pub fn deinit(l: *Listing) void {
        if (l.mailmap) |*m| m.deinit();
        for (l.describers.items) |d| if (d) |describer| describer.deinit();
        l.arena.deinit();
        l.* = undefined;
    }

    fn a(l: *Listing) Allocator {
        return l.arena.allocator();
    }

    // -- collecting -------------------------------------------------------

    /// Gather the refs `filter` lets through, in the order a ref iteration
    /// gives them: by name, a detached `HEAD` last. The reachability
    /// filters are applied once every ref is in.
    pub fn collect(l: *Listing, filter: Filter) ErrorNamespace.Error!void {
        const gpa = l.gpa;
        const io = l.io;
        // Every ref is asked of the same globs, so they are compiled once.
        const patterns: Patterns = .{
            .include = try .compile(l.a(), filter, filter.patterns),
            .exclude = try .compile(l.a(), filter, filter.exclude),
        };
        const store = l.repo.refStore();
        var candidates: std.ArrayList(refs_mod.Named) = .empty;
        defer candidates.deinit(gpa);
        var listing = try store.list(gpa, io, if (filter.kinds.onlyOne()) |k| switch (k) {
            .branch => "refs/heads/",
            .remote => "refs/remotes/",
            .tag => "refs/tags/",
            else => unreachable,
        } else "refs/");
        defer listing.deinit();
        // `HEAD` and the root refs, from the ref store, which knows where
        // its format keeps them.
        var roots: refs_mod.Store.Listing = if (filter.kinds.root_refs)
            try store.root().list(gpa, io)
        else
            .{ .gpa = gpa, .arena = .{}, .entries = &.{} };
        defer roots.deinit();
        // the root refs sort among the others, by name
        var i: usize = 0;
        var j: usize = 0;
        while (i < listing.entries.len or j < roots.entries.len) {
            if (j < roots.entries.len and (i == listing.entries.len or std.mem.order(u8, roots.entries[j].name, listing.entries[i].name) == .lt)) {
                try candidates.append(gpa, roots.entries[j]);
                j += 1;
            } else {
                try candidates.append(gpa, listing.entries[i]);
                i += 1;
            }
        }
        for (candidates.items) |entry| {
            if (filter.start_after) |marker| {
                if (std.mem.order(u8, entry.name, marker) != .gt) continue;
            }
            try l.consider(filter, &patterns, entry.name, entry.target, entry.peeled, !entry.loose, true);
        }
        if (!filter.kinds.root_refs and filter.kinds.detached_head) {
            if (try store.read(gpa, io, "HEAD")) |head| {
                const target: refs_mod.Ref = switch (head) {
                    .direct => |oid| .{ .direct = oid },
                    .symbolic => |name| blk: {
                        defer gpa.free(name);
                        break :blk .{ .symbolic = try l.a().dupe(u8, name) };
                    },
                };
                if (filter.start_after == null or std.mem.order(u8, "HEAD", filter.start_after.?) == .gt)
                    // git hands `HEAD` on without the name it points at
                    try l.consider(filter, &patterns, "HEAD", target, null, false, false);
            }
        }
        try l.reachFilter(filter.merged, true);
        try l.reachFilter(filter.no_merged, false);
    }

    /// git's `apply_ref_filter` for one ref.
    fn consider(l: *Listing, filter: Filter, patterns: *const Patterns, name: []const u8, target: refs_mod.Ref, peeled: ?Oid, is_packed: bool, show_target: bool) ErrorNamespace.Error!void {
        const gpa = l.gpa;
        const io = l.io;
        const store = l.repo.refStore();
        var oid: Oid = undefined;
        var symref: ?[]const u8 = null;
        var packed_at_end = false;
        switch (target) {
            .direct => |direct| oid = direct,
            .symbolic => |to| {
                // a symbolic ref that resolves nowhere is broken, and left out
                const resolved = (store.resolve(gpa, io, name) catch return) orelse return;
                defer gpa.free(resolved.name);
                oid = resolved.oid;
                symref = try l.a().dupe(u8, to);
                // git's flags are those of every step, the last one's
                // `packed` among them
                packed_at_end = resolved.from_packed;
            },
        }
        // a ref naming no object, or the null one, is broken too
        if (oid.isZero()) return;
        if (!try l.repo.objectDatabase().exists(io, oid)) {
            _ = l.repo.objectDatabase().readHeader(io, oid) catch |err| switch (err) {
                error.ObjectNotFound => return,
                else => |e| return e,
            };
        }
        var kind = if (filter.kinds.onlyOne()) |only| only else Kind.of(name);
        if (filter.kinds.root_refs and kind == .detached_head) {
            kind = .root_ref;
        } else if (!kind.in(filter.kinds)) return;
        if (!patterns.include.matches(filter, name, true)) return;
        if (patterns.exclude.matches(filter, name, false)) return;
        if (filter.points_at.len != 0 and !try l.pointsAt(filter.points_at, oid)) return;
        var commit: ?Oid = null;
        if (filter.merged.len != 0 or filter.no_merged.len != 0 or filter.contains.len != 0 or
            filter.no_contains.len != 0 or filter.commits_only)
        {
            commit = (try l.peelToCommit(oid)) orelse return;
            if (filter.contains.len != 0 and !try l.containsAny(commit.?, filter.contains)) return;
            if (filter.no_contains.len != 0 and try l.containsAny(commit.?, filter.no_contains)) return;
        }
        const item = try l.a().create(Item);
        item.* = .{
            .name = try l.a().dupe(u8, name),
            .oid = oid,
            .peeled = peeled,
            .symref = if (show_target) symref else null,
            .is_symref = symref != null,
            .is_packed = is_packed or packed_at_end,
            .kind = kind,
            .commit = commit,
        };
        try l.items.append(l.a(), item);
    }

    fn pointsAt(l: *Listing, wanted: []const Oid, oid: Oid) ErrorNamespace.Error!bool {
        for (wanted) |w| if (w.eql(oid)) return true;
        var current = oid;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            const found = try l.repo.objectDatabase().read(l.io, current);
            defer l.repo.objectDatabase().allocator().free(found.bytes);
            if (found.type != .tag) return false;
            var tag = try object.Tag.parse(l.gpa, l.repo.objectFormat(), found.bytes);
            defer tag.deinit();
            for (wanted) |w| if (w.eql(tag.target)) return true;
            current = tag.target;
        }
        return false;
    }

    /// The commit `oid` peels to, or `null` when it is not commit-ish.
    fn peelToCommit(l: *Listing, oid: Oid) ErrorNamespace.Error!?Oid {
        var current = oid;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            const header = l.repo.objectDatabase().readHeader(l.io, current) catch |err| switch (err) {
                error.ObjectNotFound => return null,
                else => |e| return e,
            };
            switch (header.type) {
                .commit => return current,
                .tag => {
                    const found = try l.repo.objectDatabase().read(l.io, current);
                    defer l.repo.objectDatabase().allocator().free(found.bytes);
                    var tag = try object.Tag.parse(l.gpa, l.repo.objectFormat(), found.bytes);
                    defer tag.deinit();
                    current = tag.target;
                },
                else => return null,
            }
        }
        return null;
    }

    fn containsAny(l: *Listing, commit: Oid, wanted: []const Oid) ErrorNamespace.Error!bool {
        for (wanted) |w| {
            if (try revwalk.isAncestor(l.gpa, l.io, l.repo.objectDatabase(), .{ .ancestor = w, .descendant = commit }, .{})) return true;
        }
        return false;
    }

    /// git's `reach_filter`: keep the refs one of `bases` reaches, or
    /// those none does.
    fn reachFilter(l: *Listing, bases: []const Oid, include_reached: bool) ErrorNamespace.Error!void {
        if (bases.len == 0) return;
        var kept: usize = 0;
        for (l.items.items) |item| {
            var reached = false;
            for (bases) |base| {
                if (try revwalk.isAncestor(l.gpa, l.io, l.repo.objectDatabase(), .{ .ancestor = item.commit.?, .descendant = base }, .{})) {
                    reached = true;
                    break;
                }
            }
            if (reached == include_reached) {
                l.items.items[kept] = item;
                kept += 1;
            }
        }
        l.items.shrinkRetainingCapacity(kept);
    }

    // -- atoms ------------------------------------------------------------

    /// git's `parse_ref_filter_atom`: the atom `text` names, added once.
    fn atomIndex(l: *Listing, text: []const u8) ErrorNamespace.Error!usize {
        for (l.atoms.items, 0..) |atom, i| {
            if (std.mem.eql(u8, atom.name, text)) return i;
        }
        var sp = text;
        const deref = sp.len > 0 and sp[0] == '*';
        if (deref) sp = sp[1..];
        if (sp.len == 0) return error.MalformedFormat;
        const colon = std.mem.findScalar(u8, sp, ':');
        const base = sp[0 .. colon orelse sp.len];
        const kind = std.meta.stringToEnum(AtomKind, base) orelse return error.UnknownField;
        var arg: ?[]const u8 = if (colon) |c| sp[c + 1 ..] else null;
        if (arg != null and arg.?.len == 0) arg = null;
        var atom: Atom = .{
            .kind = kind,
            .name = try l.a().dupe(u8, text),
            .deref = deref,
            .field = fieldTypeOf(kind),
        };
        try l.parseArgument(&atom, arg);
        try l.atoms.append(l.a(), atom);
        return l.atoms.items.len - 1;
    }

    fn parseArgument(l: *Listing, atom: *Atom, arg: ?[]const u8) ErrorNamespace.Error!void {
        switch (atom.kind) {
            .refname, .symref => atom.refname = try parseRefnameOption(arg),
            .upstream, .push => try parseRemoteArgument(atom, arg),
            .objecttype, .deltabase, .body, .rest, .HEAD => if (arg != null) return error.BadFieldArgument,
            .objectsize => if (arg) |text| {
                if (!std.mem.eql(u8, text, "disk")) return error.BadFieldArgument;
                atom.size_disk = true;
            },
            .subject => if (arg) |text| {
                if (!std.mem.eql(u8, text, "sanitize")) return error.BadFieldArgument;
                atom.contents = .sub_sanitize;
            } else {
                atom.contents = .sub;
            },
            .signature => atom.signature = parseSignatureOption(arg) orelse return error.BadFieldArgument,
            .trailers => {
                atom.contents = .trailers;
                atom.trailers = try parseTrailerOptions(l.a(), arg);
            },
            .contents => if (arg) |text| {
                if (std.mem.eql(u8, text, "body")) {
                    atom.contents = .body;
                } else if (std.mem.eql(u8, text, "size")) {
                    atom.field = .ulong;
                    atom.contents = .length;
                } else if (std.mem.eql(u8, text, "signature")) {
                    atom.contents = .sig;
                } else if (std.mem.eql(u8, text, "subject")) {
                    atom.contents = .sub;
                } else if (std.mem.eql(u8, text, "trailers")) {
                    atom.contents = .trailers;
                    atom.trailers = try parseTrailerOptions(l.a(), null);
                } else if (std.mem.startsWith(u8, text, "trailers:")) {
                    atom.contents = .trailers;
                    atom.trailers = try parseTrailerOptions(l.a(), text["trailers:".len..]);
                } else if (std.mem.startsWith(u8, text, "lines=")) {
                    atom.contents = .lines;
                    atom.lines = parseUnsigned(text["lines=".len..]) orelse return error.BadFieldArgument;
                } else return error.BadFieldArgument;
            },
            .describe => try l.parseDescribeArgument(atom, arg),
            .raw => if (arg) |text| {
                if (!std.mem.eql(u8, text, "size")) return error.BadFieldArgument;
                atom.field = .ulong;
                atom.raw_length = true;
            },
            .objectname, .tree, .parent => if (arg) |text| {
                if (std.mem.eql(u8, text, "short")) {
                    atom.oid = .short;
                } else if (std.mem.startsWith(u8, text, "short=")) {
                    const n = parseUnsigned(text["short=".len..]) orelse return error.BadFieldArgument;
                    if (n == 0) return error.BadFieldArgument;
                    atom.oid = .{ .length = @max(n, abbrev_mod.minimum) };
                } else return error.BadFieldArgument;
            },
            .authorname, .committername, .taggername => if (arg) |text| {
                if (!std.mem.eql(u8, text, "mailmap")) return error.BadFieldArgument;
                atom.name_mailmap = true;
            },
            .authoremail, .committeremail, .taggeremail => {
                var rest = arg orelse return;
                while (true) {
                    if (std.mem.startsWith(u8, rest, "trim")) {
                        atom.email_trim = true;
                        rest = rest[4..];
                    } else if (std.mem.startsWith(u8, rest, "localpart")) {
                        atom.email_localpart = true;
                        rest = rest[9..];
                    } else if (std.mem.startsWith(u8, rest, "mailmap")) {
                        atom.email_mailmap = true;
                        rest = rest[7..];
                    } else return error.BadFieldArgument;
                    if (rest.len == 0) break;
                    if (rest[0] != ',') return error.BadFieldArgument;
                    rest = rest[1..];
                }
            },
            .authordate, .committerdate, .taggerdate, .creatordate => if (arg) |text| {
                atom.date = gitdate.Mode.parse(text) orelse return error.UnknownDateFormat;
                // a formatted date sorts as text
                atom.field = .str;
            },
            .@"align" => try parseAlignArgument(atom, arg),
            .@"if" => if (arg) |text| {
                if (std.mem.startsWith(u8, text, "equals=")) {
                    atom.compare = .equal;
                    atom.compare_with = text["equals=".len..];
                } else if (std.mem.startsWith(u8, text, "notequals=")) {
                    atom.compare = .unequal;
                    atom.compare_with = text["notequals=".len..];
                } else return error.BadFieldArgument;
            },
            .color => {
                const text = arg orelse return error.BadFieldArgument;
                if (!validColor(text)) return error.BadFieldArgument;
            },
            .@"ahead-behind", .@"is-base" => {
                const text = arg orelse return error.BadFieldArgument;
                atom.base_name = text;
                const resolved = revparse_mod.resolve(l.gpa, l.io, l.repo, text) catch return error.UnknownCommit;
                atom.base = (try l.peelToCommit(resolved)) orelse return error.UnknownCommit;
            },
            else => {},
        }
        if (atom.kind == .HEAD) {
            if (try l.repo.refStore().resolve(l.gpa, l.io, "HEAD")) |head| {
                defer l.gpa.free(head.name);
                atom.head = try l.a().dupe(u8, head.name);
            } else {
                atom.head = null;
            }
        }
    }

    fn parseRemoteArgument(atom: *Atom, arg: ?[]const u8) ErrorNamespace.Error!void {
        atom.push_remote = false;
        const text = arg orelse return;
        var params = std.mem.splitScalar(u8, text, ',');
        while (params.next()) |s| {
            if (std.mem.eql(u8, s, "track")) {
                atom.remote = .track;
            } else if (std.mem.eql(u8, s, "trackshort")) {
                atom.remote = .trackshort;
            } else if (std.mem.eql(u8, s, "nobracket")) {
                atom.nobracket = true;
            } else if (std.mem.eql(u8, s, "remotename")) {
                atom.remote = .remotename;
                atom.push_remote = true;
            } else if (std.mem.eql(u8, s, "remoteref")) {
                atom.remote = .remoteref;
                atom.push_remote = true;
            } else {
                atom.remote = .ref;
                // git hands the whole argument on
                atom.refname = try parseRefnameOption(text);
            }
        }
    }

    fn parseDescribeArgument(l: *Listing, atom: *Atom, arg: ?[]const u8) ErrorNamespace.Error!void {
        var rest = arg orelse "";
        var matches: std.ArrayList([]const u8) = .empty;
        var excludes: std.ArrayList([]const u8) = .empty;
        while (rest.len != 0) {
            if (matchArgValue(rest, "tags")) |m| {
                atom.describe.tags = if (m.value) |v| maybeBool(v) orelse return error.BadFieldArgument else true;
                rest = m.rest;
            } else if (matchArgValue(rest, "abbrev")) |m| {
                const v = m.value orelse return error.BadFieldArgument;
                const n = std.fmt.parseInt(i64, v, 10) catch return error.BadFieldArgument;
                if (n < 0) return error.BadFieldArgument;
                atom.describe.abbrev = @intCast(@min(n, std.math.maxInt(u32)));
                rest = m.rest;
            } else if (matchArgValue(rest, "match")) |m| {
                const v = m.value orelse return error.BadFieldArgument;
                if (v.len == 0) return error.BadFieldArgument;
                try matches.append(l.a(), v);
                rest = m.rest;
            } else if (matchArgValue(rest, "exclude")) |m| {
                const v = m.value orelse return error.BadFieldArgument;
                if (v.len == 0) return error.BadFieldArgument;
                try excludes.append(l.a(), v);
                rest = m.rest;
            } else return error.BadFieldArgument;
        }
        atom.describe.match = matches.items;
        atom.describe.exclude = excludes.items;
    }

    fn parseAlignArgument(atom: *Atom, arg: ?[]const u8) ErrorNamespace.Error!void {
        const text = arg orelse return error.BadFieldArgument;
        var width: ?u32 = null;
        var params = std.mem.splitScalar(u8, text, ',');
        while (params.next()) |s| {
            if (std.mem.startsWith(u8, s, "position=")) {
                atom.@"align".position = alignPosition(s["position=".len..]) orelse return error.BadFieldArgument;
            } else if (std.mem.startsWith(u8, s, "width=")) {
                width = parseUnsigned(s["width=".len..]) orelse return error.BadFieldArgument;
            } else if (parseUnsigned(s)) |w| {
                width = w;
            } else if (alignPosition(s)) |p| {
                atom.@"align".position = p;
            } else return error.BadFieldArgument;
        }
        atom.@"align".width = width orelse return error.BadFieldArgument;
    }

    fn alignPosition(s: []const u8) ?@FieldType(Align, "position") {
        if (std.mem.eql(u8, s, "right")) return .right;
        if (std.mem.eql(u8, s, "middle")) return .middle;
        if (std.mem.eql(u8, s, "left")) return .left;
        return null;
    }

    /// git's `verify_ref_format`: compile `text`, every atom checked.
    pub fn parseFormat(l: *Listing, text: []const u8, quote: Quote) ErrorNamespace.Error!Format {
        var parts: std.ArrayList(Format.Part) = .empty;
        var cp: usize = 0;
        while (cp < text.len) {
            const sp = findNext(text, cp) orelse break;
            const ep = std.mem.findScalarPos(u8, text, sp, ')') orelse return error.MalformedFormat;
            if (cp < sp) try parts.append(l.a(), .{ .literal = text[cp..sp] });
            const index = try l.atomIndex(text[sp + 2 .. ep]);
            const atom = l.atoms.items[index];
            if (atom.kind == .rest) return error.RejectedField;
            if ((quote == .python or quote == .shell or quote == .tcl) and atom.kind == .raw and !atom.raw_length)
                return error.RawNeedsBinarySafeQuote;
            try parts.append(l.a(), .{ .atom = index });
            cp = ep + 1;
        }
        if (cp < text.len) try parts.append(l.a(), .{ .literal = text[cp..] });
        return .{ .parts = parts.items, .quote = quote };
    }

    /// git's `find_next`: the next `%(`, past `%%`.
    fn findNext(text: []const u8, from: usize) ?usize {
        var cp = from;
        while (cp < text.len) : (cp += 1) {
            if (text[cp] == '%') {
                if (cp + 1 < text.len and text[cp + 1] == '(') return cp;
                if (cp + 1 < text.len and text[cp + 1] == '%') cp += 1;
            }
        }
        return null;
    }

    // -- sorting ----------------------------------------------------------

    /// Sort by `keys`, the last the first compared, then by name: git's
    /// `ref_array_sort`. No keys leaves the order as it is.
    pub fn sort(l: *Listing, keys: []const SortKey, options: SortOptions) ErrorNamespace.Error!void {
        if (keys.len == 0) return;
        var indexes = try l.a().alloc(usize, keys.len);
        for (keys, 0..) |key, i| indexes[i] = try l.atomIndex(key.atom);
        l.sort_keys = keys;
        l.sort_atoms = indexes;
        l.sort_options = options;
        // values first, so a comparison cannot fail
        for (l.items.items) |item| {
            for (indexes) |index| _ = try l.atomValue(item, index);
        }
        try l.prepare();
        for (l.items.items) |item| {
            for (indexes) |index| _ = try l.atomValue(item, index);
        }
        if (l.prereleases == null) l.prereleases = try prereleaseSuffixes(l.a(), l.repo.configuration());
        std.mem.sort(*Item, l.items.items, l, lessItem);
    }

    fn lessItem(l: *Listing, x: *Item, y: *Item) bool {
        return l.compareItems(x, y) < 0;
    }

    fn compareItems(l: *Listing, x: *Item, y: *Item) i32 {
        var k = l.sort_keys.len;
        while (k > 0) {
            k -= 1;
            const c = l.compareKey(k, x, y);
            if (c != 0) return c;
        }
        const by_name = if (l.sort_options.ignore_case) caseOrder(x.name, y.name) else orderInt(std.mem.order(u8, x.name, y.name));
        return by_name;
    }

    fn compareKey(l: *Listing, k: usize, x: *Item, y: *Item) i32 {
        const key = l.sort_keys[k];
        const index = l.sort_atoms[k];
        const atom = l.atoms.items[index];
        const vx = x.values.items[index].?;
        const vy = y.values.items[index].?;
        if (l.sort_options.detached_head_first and (x.kind == .detached_head or y.kind == .detached_head)) {
            if (x.kind == .detached_head and y.kind != .detached_head) return -1;
            if (y.kind == .detached_head and x.kind != .detached_head) return 1;
        }
        var c: i32 = 0;
        if (key.version) {
            c = versioncmp(cString(vx), cString(vy), l.prereleases orelse &.{});
        } else if (atom.field == .str) {
            if (!vx.sized and !vy.sized) {
                c = if (l.sort_options.ignore_case) caseOrder(cString(vx), cString(vy)) else orderInt(std.mem.order(u8, cString(vx), cString(vy)));
            } else {
                const n = @min(vx.s.len, vy.s.len);
                c = if (l.sort_options.ignore_case) caseOrder(vx.s[0..n], vy.s[0..n]) else orderInt(std.mem.order(u8, vx.s[0..n], vy.s[0..n]));
                if (c == 0) c = orderInt(std.math.order(vx.s.len, vy.s.len));
            }
        } else {
            c = orderInt(std.math.order(vx.num, vy.num));
        }
        return if (key.reverse) -c else c;
    }

    // -- values -----------------------------------------------------------

    /// Batch work some atoms need over the whole listing: `ahead-behind`
    /// and `is-base`. git does it after filtering and before sorting.
    fn prepare(l: *Listing) ErrorNamespace.Error!void {
        var bases: usize = 0;
        var is_bases: usize = 0;
        for (l.atoms.items) |atom| {
            if (atom.kind == .@"ahead-behind") bases += 1;
            if (atom.kind == .@"is-base") is_bases += 1;
        }
        if (bases != 0) {
            for (l.items.items) |item| {
                if (item.counts != null) continue;
                const tip = (try l.commitByName(item.name)) orelse {
                    item.counts = &.{};
                    continue;
                };
                const counts = try l.a().alloc(?[2]usize, bases);
                var j: usize = 0;
                for (l.atoms.items) |atom| {
                    if (atom.kind != .@"ahead-behind") continue;
                    counts[j] = .{ try l.countOnly(tip, atom.base.?), try l.countOnly(atom.base.?, tip) };
                    j += 1;
                }
                item.counts = counts;
            }
        }
        if (is_bases != 0 and l.items.items.len != 0 and l.items.items[0].is_base == null) {
            var commits: std.ArrayList(Oid) = .empty;
            var owners: std.ArrayList(*Item) = .empty;
            for (l.items.items) |item| {
                item.is_base = try l.a().alloc(?[]const u8, is_bases);
                @memset(item.is_base.?, null);
                const c = (try l.commitByName(item.name)) orelse continue;
                try commits.append(l.a(), c);
                try owners.append(l.a(), item);
            }
            var j: usize = 0;
            for (l.atoms.items) |atom| {
                if (atom.kind != .@"is-base") continue;
                const at = try l.branchBaseForTip(atom.base.?, commits.items);
                if (at) |index| owners.items[index].is_base.?[j] = atom.base_name;
                j += 1;
            }
        }
    }

    /// The commit `name` names, as git's `lookup_commit_reference_by_name`.
    fn commitByName(l: *Listing, name: []const u8) ErrorNamespace.Error!?Oid {
        const resolved = revparse_mod.resolve(l.gpa, l.io, l.repo, name) catch return null;
        return l.peelToCommit(resolved);
    }

    /// How many commits `tip` reaches that `base` does not.
    fn countOnly(l: *Listing, tip: Oid, base: Oid) ErrorNamespace.Error!usize {
        var walk = revwalk.Walk.init(l.gpa, l.repo.objectDatabase());
        defer walk.deinit();
        try walk.push(tip);
        try walk.hide(base);
        return walk.count(l.io);
    }

    /// git's `get_branch_base_for_tip`: of `bases`, the one whose
    /// first-parent history meets `tip`'s first, ties to the earliest.
    fn branchBaseForTip(l: *Listing, tip: Oid, bases: []const Oid) ErrorNamespace.Error!?usize {
        if (bases.len == 0) return null;
        const gpa = l.gpa;
        var generations: Oid.Map(u64) = .empty;
        defer generations.deinit(gpa);
        var best: Oid.Map(i64) = .empty;
        defer best.deinit(gpa);
        const Entry = struct { oid: Oid, generation: u64, date: i64, order: usize };
        var queue: std.ArrayList(Entry) = .empty;
        defer queue.deinit(gpa);
        var counter: usize = 0;
        const Push = struct {
            fn put(allocator: Allocator, list: *std.ArrayList(Entry), e: Entry) Allocator.Error!void {
                try list.append(allocator, e);
            }
        };
        try best.put(gpa, tip, -1);
        try Push.put(gpa, &queue, .{ .oid = tip, .generation = try l.generation(&generations, tip), .date = try l.commitDate(tip), .order = counter });
        counter += 1;
        var best_index: i64 = -1;
        for (bases, 0..) |c, i| {
            if (best.get(c)) |b| {
                if (b == -1) {
                    best_index = @intCast(i + 1);
                    return @intCast(best_index - 1);
                }
                continue;
            }
            try best.put(gpa, c, @intCast(i + 1));
            try Push.put(gpa, &queue, .{ .oid = c, .generation = try l.generation(&generations, c), .date = try l.commitDate(c), .order = counter });
            counter += 1;
        }
        var branch_point: ?Oid = null;
        while (queue.items.len != 0) {
            // newest generation, then newest date, then first in
            var top: usize = 0;
            for (queue.items, 0..) |e, i| {
                const t = queue.items[top];
                if (e.generation > t.generation or (e.generation == t.generation and (e.date > t.date or (e.date == t.date and e.order < t.order)))) top = i;
            }
            const c = queue.orderedRemove(top);
            const best_for_c = best.get(c.oid).?;
            if (branch_point) |bp| if (bp.eql(c.oid)) break;
            const parents = try l.parentsOf(c.oid);
            if (parents.len == 0) continue;
            const parent = parents[0];
            const best_for_p = best.get(parent) orelse 0;
            if (best_for_p == 0) {
                try best.put(gpa, parent, best_for_c);
                try Push.put(gpa, &queue, .{ .oid = parent, .generation = try l.generation(&generations, parent), .date = try l.commitDate(parent), .order = counter });
                counter += 1;
                continue;
            }
            if (best_for_p > 0 and best_for_c > 0) {
                if (best_for_c < best_for_p) try best.put(gpa, parent, best_for_c);
                continue;
            }
            const positive = if (best_for_c < 0) best_for_p else best_for_c;
            if (best_index < 0 or positive < best_index) best_index = positive;
            try best.put(gpa, parent, -1);
            branch_point = parent;
        }
        return if (best_index > 0) @intCast(best_index - 1) else null;
    }

    fn commitNode(l: *Listing, oid: Oid) ErrorNamespace.Error!CommitNode {
        if (l.commits.get(oid)) |node| return node;
        const found = try l.repo.objectDatabase().read(l.io, oid);
        defer l.repo.objectDatabase().allocator().free(found.bytes);
        if (found.type != .commit) return error.NotACommit;
        var commit = try object.Commit.parse(l.gpa, l.repo.objectFormat(), found.bytes);
        defer commit.deinit();
        const node: CommitNode = .{ .parents = try l.a().dupe(Oid, commit.parents), .date = commit.committer.when_secs };
        try l.commits.put(l.a(), oid, node);
        return node;
    }

    fn parentsOf(l: *Listing, oid: Oid) ErrorNamespace.Error![]const Oid {
        return (try l.commitNode(oid)).parents;
    }

    fn commitDate(l: *Listing, oid: Oid) ErrorNamespace.Error!i64 {
        return (try l.commitNode(oid)).date;
    }

    /// A commit's topological level, as git computes one where no
    /// commit-graph gives it.
    fn generation(l: *Listing, cache: *Oid.Map(u64), oid: Oid) ErrorNamespace.Error!u64 {
        if (cache.get(oid)) |g| return g;
        var stack: std.ArrayList(Oid) = .empty;
        defer stack.deinit(l.gpa);
        try stack.append(l.gpa, oid);
        while (stack.items.len != 0) {
            const top = stack.items[stack.items.len - 1];
            if (cache.contains(top)) {
                _ = stack.pop();
                continue;
            }
            const parents = try l.parentsOf(top);
            var max: u64 = 0;
            var ready = true;
            for (parents) |p| {
                if (cache.get(p)) |g| {
                    max = @max(max, g);
                } else {
                    ready = false;
                    try stack.append(l.gpa, p);
                }
            }
            if (ready) {
                try cache.put(l.gpa, top, max + 1);
                _ = stack.pop();
            }
        }
        return cache.get(oid).?;
    }

    fn atomValue(l: *Listing, item: *Item, index: usize) ErrorNamespace.Error!Value {
        while (item.values.items.len < l.atoms.items.len) try item.values.append(l.a(), null);
        if (item.values.items[index]) |v| return v;
        const v = try l.compute(item, l.atoms.items[index]);
        item.values.items[index] = v;
        return v;
    }

    fn compute(l: *Listing, item: *Item, atom: Atom) ErrorNamespace.Error!Value {
        const ar = l.a();
        switch (atom.kind) {
            .refname => {
                const name = if (item.kind == .detached_head) try l.headDescription() else try l.showRef(atom.refname, item.name);
                return .{ .s = if (atom.deref) try ar.print("{s}^{{}}", .{name}) else name };
            },
            .symref => {
                const name = if (item.symref) |t| try l.showRef(atom.refname, t) else "";
                return .{ .s = if (atom.deref) try ar.print("{s}^{{}}", .{name}) else name };
            },
            .worktreepath => return .{ .s = if (item.kind == .branch) try l.worktreePath(item.name) else "" },
            .upstream => {
                const short = if (std.mem.startsWith(u8, item.name, "refs/heads/")) item.name["refs/heads/".len..] else return .{};
                const upstream = (try l.upstreamOf(short)) orelse return .{};
                return .{ .s = try l.remoteDetails(atom, upstream, short, false) };
            },
            .push => {
                const short = if (std.mem.startsWith(u8, item.name, "refs/heads/")) item.name["refs/heads/".len..] else return .{};
                var target: []const u8 = "";
                if (!atom.push_remote) target = (try l.pushOf(short)) orelse return .{};
                return .{ .s = try l.remoteDetails(atom, target, short, true) };
            },
            .color => return .{},
            .flag => {
                var parts: std.ArrayList(u8) = .empty;
                if (item.is_symref) try parts.appendSlice(ar, ",symref");
                if (item.is_packed) try parts.appendSlice(ar, ",packed");
                return .{ .s = if (parts.items.len == 0) "" else parts.items[1..] };
            },
            .HEAD => return .{ .s = if (atom.head != null and std.mem.eql(u8, atom.head.?, item.name)) "*" else " " },
            .@"align" => return .{ .handler = .@"align" },
            .end => return .{ .handler = .end },
            .@"if" => return .{ .handler = .@"if" },
            .then => return .{ .handler = .then },
            .@"else" => return .{ .handler = .@"else" },
            .rest => return .{},
            .@"ahead-behind" => {
                if (item.counts == null) try l.prepare();
                const counts = item.counts.?;
                if (counts.len == 0) return .{};
                const n = l.ordinal(atom, .@"ahead-behind");
                const pair = counts[n].?;
                return .{ .s = try ar.print("{d} {d}", .{ pair[0], pair[1] }) };
            },
            .@"is-base" => {
                if (item.is_base == null) try l.prepare();
                const n = l.ordinal(atom, .@"is-base");
                const name = item.is_base.?[n] orelse return .{};
                return .{ .s = try ar.print("({s})", .{name}) };
            },
            .objectname => if (!atom.deref) return .{ .s = try l.showOid(atom.oid, item.oid) },
            else => {},
        }
        // what the object holds
        const data = if (atom.deref) (try l.derefObject(item)) orelse return .{} else try l.itemObject(item);
        return l.objectValue(atom, data);
    }

    /// Which of the atoms of `kind` this is, counting in the order they
    /// were added: git numbers `ahead-behind` and `is-base` values so.
    fn ordinal(l: *Listing, atom: Atom, kind: AtomKind) usize {
        var n: usize = 0;
        for (l.atoms.items) |other| {
            if (other.kind != kind) continue;
            if (std.mem.eql(u8, other.name, atom.name)) return n;
            n += 1;
        }
        return n;
    }

    fn itemObject(l: *Listing, item: *Item) ErrorNamespace.Error!ObjectData {
        if (item.object) |data| return data;
        const found = l.repo.objectDatabase().read(l.io, item.oid) catch |err| switch (err) {
            error.ObjectNotFound => return error.MissingObject,
            else => |e| return e,
        };
        defer l.repo.objectDatabase().allocator().free(found.bytes);
        item.object = .{ .oid = item.oid, .type = found.type, .bytes = try l.a().dupe(u8, found.bytes) };
        return item.object.?;
    }

    fn derefObject(l: *Listing, item: *Item) ErrorNamespace.Error!?ObjectData {
        if (item.deref_done) return item.deref;
        item.deref_done = true;
        const own = try l.itemObject(item);
        if (own.type != .tag) return null;
        const peeled = item.peeled orelse {
            var current = own;
            var depth: usize = 0;
            while (current.type == .tag) : (depth += 1) {
                if (depth > 64) return error.BadTag;
                var tag = object.Tag.parse(l.gpa, l.repo.objectFormat(), current.bytes) catch return error.BadTag;
                defer tag.deinit();
                const next = l.repo.objectDatabase().read(l.io, tag.target) catch |err| switch (err) {
                    error.ObjectNotFound => return error.BadTag,
                    else => |e| return e,
                };
                defer l.repo.objectDatabase().allocator().free(next.bytes);
                if (next.type != tag.target_type) return error.BadTag;
                current = .{ .oid = tag.target, .type = next.type, .bytes = try l.a().dupe(u8, next.bytes) };
            }
            item.deref = current;
            return current;
        };
        const found = l.repo.objectDatabase().read(l.io, peeled) catch |err| switch (err) {
            error.ObjectNotFound => return error.MissingObject,
            else => |e| return e,
        };
        defer l.repo.objectDatabase().allocator().free(found.bytes);
        item.deref = .{ .oid = peeled, .type = found.type, .bytes = try l.a().dupe(u8, found.bytes) };
        return item.deref;
    }

    fn objectValue(l: *Listing, atom: Atom, data: ObjectData) ErrorNamespace.Error!Value {
        const ar = l.a();
        switch (atom.kind) {
            .objecttype => return .{ .s = data.type.name() },
            .objectsize => {
                const n: u64 = if (atom.size_disk) (try l.repo.objectDatabase().placement(l.io, data.oid)).disk_size else data.bytes.len;
                return .{ .s = try ar.print("{d}", .{n}), .num = n };
            },
            .deltabase => {
                // git asks for the object's content when any atom reads it,
                // and a pack hands back the content's type rather than the
                // delta's: no base
                const base = if (l.contentWanted(atom.deref))
                    Oid.zero(l.repo.objectFormat())
                else
                    (try l.repo.objectDatabase().placement(l.io, data.oid)).delta_base orelse Oid.zero(l.repo.objectFormat());
                var buf: [hash.max_hex_len]u8 = undefined;
                return .{ .s = try ar.dupe(u8, base.hex(&buf)) };
            },
            .objectname => return .{ .s = try l.showOid(atom.oid, data.oid) },
            .raw => {
                if (atom.raw_length) return .{ .s = try ar.print("{d}", .{data.bytes.len}), .num = data.bytes.len };
                return .{ .s = data.bytes, .sized = true };
            },
            else => {},
        }
        const buf = cString(.{ .s = data.bytes });
        switch (data.type) {
            .tag => switch (atom.kind) {
                .tag => return .{ .s = headerValue(buf, "tag") orelse "" },
                .type => return .{ .s = headerValue(buf, "type") orelse "" },
                .object => return .{ .s = headerValue(buf, "object") orelse "" },
                .tagger, .taggername, .taggeremail, .taggerdate, .creator, .creatordate => return l.person(atom, buf, "tagger"),
                .describe => return l.describeValue(atom, data.oid),
                .subject, .body, .contents, .trailers => return l.contentsValue(atom, buf),
                else => return .{},
            },
            .commit => switch (atom.kind) {
                .tree => return .{ .s = try l.showOid(atom.oid, Oid.parse(l.repo.objectFormat(), headerValue(buf, "tree") orelse "") catch return .{}) },
                .numparent, .parent => {
                    var text: std.ArrayList(u8) = .empty;
                    var count: u64 = 0;
                    var lines = std.mem.splitScalar(u8, headerBlock(buf), '\n');
                    while (lines.next()) |line| {
                        if (!std.mem.startsWith(u8, line, "parent ")) continue;
                        const oid = Oid.parse(l.repo.objectFormat(), line["parent ".len..]) catch continue;
                        if (count != 0) try text.append(ar, ' ');
                        try text.appendSlice(ar, try l.showOid(atom.oid, oid));
                        count += 1;
                    }
                    if (atom.kind == .numparent) return .{ .s = try ar.print("{d}", .{count}), .num = count };
                    return .{ .s = text.items };
                },
                .author, .authorname, .authoremail, .authordate => return l.person(atom, buf, "author"),
                .committer, .committername, .committeremail, .committerdate, .creator, .creatordate => return l.person(atom, buf, "committer"),
                .signature => return l.signatureValue(atom, data),
                .describe => return l.describeValue(atom, data.oid),
                .subject, .body, .contents, .trailers => return l.contentsValue(atom, buf),
                else => return .{},
            },
            else => return .{},
        }
    }

    /// Whether git reads the content of the ref's object (`deref` false) or
    /// of what it peels to (`deref` true): an atom of that side reads it,
    /// and any `*` atom makes git read the ref's own to peel it.
    fn contentWanted(l: *const Listing, deref: bool) bool {
        for (l.atoms.items) |atom| {
            if (sourceOf(atom.kind) == .obj and atom.deref == deref) return true;
            if (!deref and atom.deref) return true;
        }
        return false;
    }

    fn showOid(l: *Listing, option: OidOption, oid: Oid) ErrorNamespace.Error![]const u8 {
        var buf: [hash.max_hex_len]u8 = undefined;
        const len: usize = switch (option) {
            .full => return l.a().dupe(u8, oid.hex(&buf)),
            .short => abbrev_mod.defaultLength(l.repo.configuration(), l.repo.objectDatabase()),
            .length => |n| n,
        };
        return l.a().dupe(u8, try abbrev_mod.unique(l.io, l.repo.objectDatabase(), oid, len, &buf));
    }

    /// git's `grab_person`: `who`'s line, or a part of it.
    fn person(l: *Listing, atom: Atom, buf: []const u8, who: []const u8) ErrorNamespace.Error!Value {
        const ar = l.a();
        const name = atom.name[@intFromBool(atom.deref)..];
        const creator = atom.kind == .creator or atom.kind == .creatordate;
        var mapped: ?[]const u8 = null;
        if (!creator and ((atom.name_mailmap and atom.kind != .authordate) or atom.email_mailmap)) {
            mapped = try l.mailmapHeader(buf);
        }
        const line = findWholine(mapped orelse buf, who) orelse return .{};
        const rest = if (creator) (if (atom.kind == .creator) "" else "date") else name[who.len..];
        if (rest.len == 0 or (creator and atom.kind == .creator)) {
            const eol = std.mem.findScalar(u8, line, '\n') orelse line.len;
            return .{ .s = line[0..eol] };
        }
        if (std.mem.startsWith(u8, rest, "name")) {
            const eol = std.mem.findScalar(u8, line, '\n') orelse line.len;
            const lt = std.mem.find(u8, line[0..eol], " <") orelse return .{};
            return .{ .s = line[0..lt] };
        }
        if (std.mem.startsWith(u8, rest, "email")) return .{ .s = copyEmail(line, atom) };
        if (std.mem.startsWith(u8, rest, "date")) {
            const eoemail = std.mem.find(u8, line, "> ") orelse return .{};
            const after = line[eoemail + 2 ..];
            var i: usize = 0;
            while (i < after.len and std.ascii.isDigit(after[i])) i += 1;
            if (i == 0) return .{};
            const secs = std.fmt.parseInt(i64, after[0..i], 10) catch return .{};
            var j = i;
            while (j < after.len and (after[j] == ' ' or after[j] == '\t')) j += 1;
            var k = j;
            if (k < after.len and (after[k] == '+' or after[k] == '-')) k += 1;
            while (k < after.len and std.ascii.isDigit(after[k])) k += 1;
            const tz = std.fmt.parseInt(i32, after[j..k], 10) catch 0;
            var out: std.ArrayList(u8) = .empty;
            gitdate.show(ar, &out, secs, tz, atom.date orelse .{}, l.context.clock) catch |err| switch (err) {
                error.DateNeedsClock => return error.DateNeedsClock,
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .s = out.items, .num = @intCast(@max(secs, 0)) };
        }
        return .{};
    }

    /// git's `apply_mailmap_to_header` over a whole object's headers.
    fn mailmapHeader(l: *Listing, buf: []const u8) ErrorNamespace.Error![]const u8 {
        if (l.mailmap == null) l.mailmap = try mailmap_mod.Mailmap.load(l.gpa, l.io, l.repo);
        const ar = l.a();
        var out: std.ArrayList(u8) = .empty;
        var at: usize = 0;
        var in_header = true;
        while (at < buf.len) {
            const eol = std.mem.findScalarPos(u8, buf, at, '\n') orelse buf.len;
            const line = buf[at..eol];
            const next = if (eol < buf.len) eol + 1 else eol;
            if (in_header and line.len == 0) in_header = false;
            if (in_header) {
                var handled = false;
                for ([_][]const u8{ "author ", "committer ", "tagger " }) |header| {
                    if (!std.mem.startsWith(u8, line, header)) continue;
                    const ident = line[header.len..];
                    const lt = std.mem.findScalar(u8, ident, '<') orelse break;
                    const gt = std.mem.findScalarPos(u8, ident, lt, '>') orelse break;
                    const name = std.mem.trimEnd(u8, ident[0..lt], " ");
                    const email = ident[lt + 1 .. gt];
                    const found = l.mailmap.?.lookup(name, email) orelse break;
                    try out.appendSlice(ar, header);
                    try out.print(ar, "{s} <{s}>", .{ found.name, found.email });
                    try out.appendSlice(ar, ident[gt + 1 ..]);
                    try out.appendSlice(ar, buf[eol..next]);
                    handled = true;
                    break;
                }
                if (handled) {
                    at = next;
                    continue;
                }
            }
            try out.appendSlice(ar, buf[at..next]);
            at = next;
        }
        return out.items;
    }

    fn signatureValue(l: *Listing, atom: Atom, data: ObjectData) ErrorNamespace.Error!Value {
        const kind = l.repo.objectFormat();
        var split = try signing.splitCommit(l.gpa, kind, data.bytes);
        var verdict: signing.Verdict = if (split) |*s| blk: {
            s.deinit(l.gpa);
            const signer = l.context.signer orelse return error.SignatureNeedsSigner;
            break :blk try signing.verifyCommit(l.io, signer, kind, data.bytes);
        } else .{ .gpa = l.gpa, .arena = .{} };
        defer verdict.deinit();
        const ar = l.a();
        return switch (atom.signature) {
            .bare => .{ .s = try ar.dupe(u8, verdict.output) },
            .signer => .{ .s = try ar.dupe(u8, verdict.signer orelse "") },
            .key => .{ .s = try ar.dupe(u8, verdict.key orelse "") },
            .fingerprint => .{ .s = try ar.dupe(u8, verdict.fingerprint orelse "") },
            .primarykeyfingerprint => .{ .s = try ar.dupe(u8, verdict.primary_fingerprint orelse "") },
            .trustlevel => .{ .s = @tagName(verdict.trust) },
            .grade => .{ .s = switch (verdict.result) {
                .good, .good_untrusted => if (verdict.trust == .undefined or verdict.trust == .never) "U" else "G",
                .bad => "B",
                .cannot_check => "E",
                .none => "N",
                .expired_signature => "X",
                .expired_key => "Y",
                .revoked_key => "R",
            } },
        };
    }

    fn describeValue(l: *Listing, atom: Atom, oid: Oid) ErrorNamespace.Error!Value {
        const index = l.ordinalDescribe(atom);
        while (l.describers.items.len <= index) {
            const options = l.atoms.items[l.describeAtomIndex(l.describers.items.len)].describe;
            const d = try l.a().create(describe_mod.Describer);
            // a repository with nothing to describe by describes nothing,
            // which git's `describe` reports on its error stream
            d.* = describe_mod.Describer.init(l.gpa, l.io, l.repo, options) catch |err| switch (err) {
                error.NoNames => {
                    try l.describers.append(l.a(), null);
                    continue;
                },
                else => return err,
            };
            try l.describers.append(l.a(), d);
        }
        const describer = l.describers.items[index] orelse return .{};
        const text = describer.describe(l.io, oid) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{},
        };
        defer l.gpa.free(text);
        return .{ .s = try l.a().dupe(u8, std.mem.trimEnd(u8, text, " \t\r\n")) };
    }

    fn ordinalDescribe(l: *Listing, atom: Atom) usize {
        var n: usize = 0;
        for (l.atoms.items) |other| {
            if (other.kind != .describe) continue;
            if (std.mem.eql(u8, other.name, atom.name)) return n;
            n += 1;
        }
        return n;
    }

    fn describeAtomIndex(l: *Listing, n: usize) usize {
        var seen: usize = 0;
        for (l.atoms.items, 0..) |other, i| {
            if (other.kind != .describe) continue;
            if (seen == n) return i;
            seen += 1;
        }
        unreachable;
    }

    /// git's `grab_sub_body_contents` for a tag or a commit.
    fn contentsValue(l: *Listing, atom: Atom, buf: []const u8) ErrorNamespace.Error!Value {
        const ar = l.a();
        const pos = findSubpos(buf);
        const option: ContentsOption = switch (atom.kind) {
            .body => .body_dep,
            else => atom.contents,
        };
        switch (option) {
            .sub => {
                var out: std.ArrayList(u8) = .empty;
                const sub = pos.sub;
                var i: usize = 0;
                while (i < sub.len) : (i += 1) {
                    if (sub[i] == '\r' and i + 1 < sub.len and sub[i + 1] == '\n') continue;
                    try out.append(ar, if (sub[i] == '\n') ' ' else sub[i]);
                }
                return .{ .s = out.items };
            },
            .sub_sanitize => {
                var out: std.ArrayList(u8) = .empty;
                try pretty.sanitizedSubject(ar, &out, pos.sub);
                return .{ .s = out.items };
            },
            .body_dep => return .{ .s = pos.body },
            .length => return .{ .s = try ar.print("{d}", .{pos.from_sub.len}), .num = pos.from_sub.len },
            .body => return .{ .s = pos.body[0..pos.nonsig_len] },
            .sig => return .{ .s = pos.sig },
            .lines => {
                var out: std.ArrayList(u8) = .empty;
                const text = pos.from_sub[0 .. pos.from_sub.len - pos.body.len + pos.nonsig_len];
                var sp: usize = 0;
                var n: u32 = 0;
                while (n < atom.lines and sp < text.len) : (n += 1) {
                    if (n != 0) try out.appendSlice(ar, "\n    ");
                    const eol = std.mem.findScalarPos(u8, text, sp, '\n');
                    try out.appendSlice(ar, text[sp .. eol orelse text.len]);
                    sp = (eol orelse break) + 1;
                }
                return .{ .s = out.items };
            },
            .bare => return .{ .s = pos.from_sub },
            .trailers => {
                if (l.trailer_settings == null) l.trailer_settings = try message.trailerSettings(ar, l.repo.configuration());
                // the message without its signature
                const msg = if (pos.sig.len != 0) pos.from_sub[0 .. pos.from_sub.len - pos.sig.len] else pos.from_sub;
                var out: std.ArrayList(u8) = .empty;
                try trailer.format(ar, l.trailer_settings.?, atom.trailers, msg, &out);
                return .{ .s = out.items };
            },
        }
    }

    fn showRef(l: *Listing, option: RefnameOption, name: []const u8) ErrorNamespace.Error![]const u8 {
        return switch (option) {
            .normal => name,
            .short => try l.shortenUnambiguous(name),
            .lstrip => |n| lstripComponents(name, n),
            .rstrip => |n| rstripComponents(name, n),
        };
    }

    /// git's `refs_shorten_unambiguous_ref`, strict as
    /// `core.warnAmbiguousRefs` (on unless set off) makes it.
    pub fn shortenUnambiguous(l: *Listing, name: []const u8) ErrorNamespace.Error![]const u8 {
        const strict = l.repo.configuration().getBool("core.warnambiguousrefs", true) catch true;
        var i: usize = rev_parse_rules.len - 1;
        while (i > 0) : (i -= 1) {
            const short = matchParseRule(name, rev_parse_rules[i]) orelse continue;
            const to_fail = if (strict) rev_parse_rules.len else i;
            var j: usize = 0;
            while (j < to_fail) : (j += 1) {
                if (i == j) continue;
                const candidate = try expandRule(l.a(), rev_parse_rules[j], short);
                if (try l.refExists(candidate)) break;
            }
            if (j == to_fail) return short;
        }
        return name;
    }

    fn refExists(l: *Listing, name: []const u8) ErrorNamespace.Error!bool {
        const resolved = l.repo.refStore().resolve(l.gpa, l.io, name) catch |err| switch (err) {
            error.InvalidRefName, error.MalformedRef, error.SymbolicRefLoop => return false,
            else => |e| return e,
        };
        if (resolved) |r| {
            l.gpa.free(r.name);
            return true;
        }
        return false;
    }

    /// git's `repo_dwim_ref`: how many of the rules find `name`, and the
    /// first one's resolved name and object.
    fn dwimRef(l: *Listing, name: []const u8) ErrorNamespace.Error!struct { count: usize, ref: []const u8 = "", oid: ?Oid = null } {
        var count: usize = 0;
        var first: []const u8 = "";
        var first_oid: ?Oid = null;
        const warn = l.repo.configuration().getBool("core.warnambiguousrefs", true) catch true;
        for (rev_parse_rules) |rule| {
            const candidate = try expandRule(l.a(), rule, name);
            const resolved = l.repo.refStore().resolve(l.gpa, l.io, candidate) catch continue;
            if (resolved) |r| {
                defer l.gpa.free(r.name);
                if (count == 0) {
                    first = try l.a().dupe(u8, r.name);
                    first_oid = r.oid;
                }
                count += 1;
                if (!warn) break;
            }
        }
        return .{ .count = count, .ref = first, .oid = first_oid };
    }

    fn worktreePath(l: *Listing, name: []const u8) ErrorNamespace.Error![]const u8 {
        if (l.worktree_map == null) {
            var map: std.StringHashMapUnmanaged([]const u8) = .empty;
            // the main worktree
            if (try l.mainHeadRef()) |head| try map.put(l.a(), head, try l.mainWorktreePath());
            var listing = try worktrees.list(l.gpa, l.io, l.repo.refStore());
            defer listing.deinit();
            for (listing.entries) |entry| {
                const branch = entry.branch orelse continue;
                const full = if (std.mem.startsWith(u8, branch, "refs/")) try l.a().dupe(u8, branch) else try l.a().print("refs/heads/{s}", .{branch});
                try map.put(l.a(), full, try normalizePath(l.a(), entry.path));
            }
            l.worktree_map = map;
        }
        return l.worktree_map.?.get(name) orelse "";
    }

    /// The branch the main worktree's `HEAD` names, followed through
    /// symbolic refs whether or not it exists, or `null` when detached.
    fn mainHeadRef(l: *Listing) ErrorNamespace.Error!?[]const u8 {
        const store = l.repo.refStore();
        // The main worktree's own `HEAD` from any worktree, through the
        // store: a reftable keeps it in the shared stack, behind a `HEAD`
        // file that is a placeholder.
        var current: []const u8 = "main-worktree/HEAD";
        var depth: u8 = 0;
        var symbolic = false;
        while (depth <= refs_mod.max_symbolic_depth) : (depth += 1) {
            const value = store.read(l.a(), l.io, current) catch null;
            switch (value orelse return if (symbolic) current else null) {
                .direct => return if (symbolic) current else null,
                .symbolic => |target| {
                    symbolic = true;
                    current = target;
                },
            }
        }
        return null;
    }

    fn mainWorktreePath(l: *Listing) ErrorNamespace.Error![]const u8 {
        const real = l.repo.commonDirectory().realPathFileAlloc(l.io, ".", l.a()) catch return "";
        var path = try normalizePath(l.a(), real);
        if (std.mem.endsWith(u8, path, "/.git")) path = path[0 .. path.len - "/.git".len];
        return path;
    }

    // -- upstream and push ------------------------------------------------

    /// git's `branch_get_upstream` for the branch `short`, or `null`.
    pub fn upstreamOf(l: *Listing, short: []const u8) ErrorNamespace.Error!?[]const u8 {
        const config = l.repo.configuration();
        var branch = try remote_mod.Branch.get(l.gpa, config, short);
        defer branch.deinit();
        const remote_name = branch.remote orelse return null;
        if (branch.merge.len == 0) return null;
        const merge = branch.merge[0];
        if (!std.mem.eql(u8, remote_name, ".")) {
            var remote = try remote_mod.Remote.get(l.gpa, config, remote_name);
            defer remote.deinit();
            const tracking = (try remote.trackingRef(l.gpa, merge)) orelse return null;
            defer l.gpa.free(tracking);
            const value = try l.a().dupe(u8, tracking);
            return value;
        }
        const found = try l.dwimRef(merge);
        if (found.count == 1) return found.ref;
        const value = try l.a().dupe(u8, merge);
        return value;
    }

    fn pushDefault(l: *Listing) enum { nothing, matching, current, upstream, simple } {
        const raw = l.repo.configuration().get("push.default") orelse return .simple;
        if (std.mem.eql(u8, raw, "nothing")) return .nothing;
        if (std.mem.eql(u8, raw, "matching")) return .matching;
        if (std.mem.eql(u8, raw, "current")) return .current;
        if (std.mem.eql(u8, raw, "upstream") or std.mem.eql(u8, raw, "tracking")) return .upstream;
        return .simple;
    }

    /// The remote a push from `branch` goes to, and whether the
    /// configuration named it: git's `pushremote_for_branch`.
    fn pushRemoteName(l: *Listing, branch: *const remote_mod.Branch) RemoteChoice {
        if (branch.push_remote) |name| return .{ .name = name, .explicit = true };
        if (l.repo.configuration().get("remote.pushdefault")) |name| {
            if (name.len != 0) return .{ .name = name, .explicit = true };
        }
        return l.fetchRemoteName(branch);
    }

    /// git's `remote_for_branch`.
    fn fetchRemoteName(l: *Listing, branch: *const remote_mod.Branch) RemoteChoice {
        if (branch.remote) |name| return .{ .name = name, .explicit = true };
        const names = remote_mod.names(l.a(), l.repo.configuration()) catch return .{ .name = "origin", .explicit = false };
        if (names.len == 1) return .{ .name = names[0], .explicit = false };
        return .{ .name = "origin", .explicit = false };
    }

    /// git's `branch_get_push` for the branch `short`, or `null`.
    pub fn pushOf(l: *Listing, short: []const u8) ErrorNamespace.Error!?[]const u8 {
        const config = l.repo.configuration();
        var branch = try remote_mod.Branch.get(l.gpa, config, short);
        defer branch.deinit();
        const full = try l.a().print("refs/heads/{s}", .{short});
        const remote_name = l.pushRemoteName(&branch).name;
        var remote = try remote_mod.Remote.get(l.gpa, config, remote_name);
        defer remote.deinit();
        if (remote.push.len != 0) {
            const dst = (try applyRefspecs(l.a(), remote.push, full)) orelse return null;
            return l.trackingForPushDest(&remote, dst);
        }
        if (remote.mirror) return l.trackingForPushDest(&remote, full);
        switch (l.pushDefault()) {
            .nothing => return null,
            .matching, .current => return l.trackingForPushDest(&remote, full),
            .upstream => return l.upstreamOf(short),
            .simple => {
                const up = (try l.upstreamOf(short)) orelse return null;
                const cur = (try l.trackingForPushDest(&remote, full)) orelse return null;
                if (!std.mem.eql(u8, up, cur)) return null;
                return cur;
            },
        }
    }

    fn trackingForPushDest(l: *Listing, remote: *const remote_mod.Remote, name: []const u8) ErrorNamespace.Error!?[]const u8 {
        return applyRefspecs(l.a(), remote.fetch, name);
    }

    /// git's `fill_remote_ref_details`.
    fn remoteDetails(l: *Listing, atom: Atom, target: []const u8, short: []const u8, for_push: bool) ErrorNamespace.Error![]const u8 {
        const ar = l.a();
        switch (atom.remote) {
            .ref => return l.showRef(atom.refname, target),
            .track, .trackshort => {
                const counts = try l.trackingCounts(short, for_push);
                if (atom.remote == .trackshort) {
                    const c = counts orelse return "";
                    if (c[0] == 0 and c[1] == 0) return "=";
                    if (c[0] == 0) return "<";
                    if (c[1] == 0) return ">";
                    return "<>";
                }
                const text: []const u8 = if (counts) |c| blk: {
                    if (c[0] == 0 and c[1] == 0) break :blk "";
                    if (c[0] == 0) break :blk try ar.print("behind {d}", .{c[1]});
                    if (c[1] == 0) break :blk try ar.print("ahead {d}", .{c[0]});
                    break :blk try ar.print("ahead {d}, behind {d}", .{ c[0], c[1] });
                } else "gone";
                if (!atom.nobracket and text.len != 0) return ar.print("[{s}]", .{text});
                return text;
            },
            .remotename => {
                var branch = try remote_mod.Branch.get(l.gpa, l.repo.configuration(), short);
                defer branch.deinit();
                const chosen = if (for_push) l.pushRemoteName(&branch) else l.fetchRemoteName(&branch);
                return if (chosen.explicit) try ar.dupe(u8, chosen.name) else "";
            },
            .remoteref => {
                var branch = try remote_mod.Branch.get(l.gpa, l.repo.configuration(), short);
                defer branch.deinit();
                if (!for_push) {
                    if (branch.remote == null or branch.merge.len == 0) return "";
                    const value = try ar.dupe(u8, branch.merge[0]);
                    return value;
                }
                var remote = try remote_mod.Remote.get(l.gpa, l.repo.configuration(), l.pushRemoteName(&branch).name);
                defer remote.deinit();
                if (remote.push.len == 0) return "";
                const full = try ar.print("refs/heads/{s}", .{short});
                return (try applyRefspecs(ar, remote.push, full)) orelse "";
            },
        }
    }

    /// git's `stat_tracking_info`: commits ahead and behind, or `null`
    /// when there is nothing to compare with.
    fn trackingCounts(l: *Listing, short: []const u8, for_push: bool) ErrorNamespace.Error!?[2]usize {
        const base = (if (for_push) try l.pushOf(short) else try l.upstreamOf(short)) orelse return null;
        const theirs_ref = (l.repo.refStore().resolve(l.gpa, l.io, base) catch return null) orelse return null;
        defer l.gpa.free(theirs_ref.name);
        const theirs = (try l.peelToCommit(theirs_ref.oid)) orelse return null;
        const full = try l.a().print("refs/heads/{s}", .{short});
        const ours_ref = (l.repo.refStore().resolve(l.gpa, l.io, full) catch return null) orelse return null;
        defer l.gpa.free(ours_ref.name);
        const ours = (try l.peelToCommit(ours_ref.oid)) orelse return null;
        if (ours.eql(theirs)) return .{ 0, 0 };
        return .{ try l.countOnly(ours, theirs), try l.countOnly(theirs, ours) };
    }

    // -- the detached HEAD ----------------------------------------------

    /// git's `get_head_description`: what `git branch` calls a detached
    /// `HEAD`.
    pub fn headDescription(l: *Listing) ErrorNamespace.Error![]const u8 {
        if (l.head_description) |d| return d;
        const ar = l.a();
        const io = l.io;
        const dir = l.repo.gitDirectory();
        var text: []const u8 = "(no branch)";
        var rebasing = false;
        var branch: ?[]const u8 = null;
        if (isDir(io, dir, "rebase-apply")) {
            if (!exists(io, dir, "rebase-apply/applying")) {
                rebasing = true;
                branch = try l.stateBranch("rebase-apply/head-name");
            }
        } else if (isDir(io, dir, "rebase-merge")) {
            rebasing = true;
            branch = try l.stateBranch("rebase-merge/head-name");
        }
        const detached = try l.detachedFrom();
        if (rebasing) {
            if (branch) |b| {
                text = try ar.print("(no branch, rebasing {s})", .{b});
            } else {
                text = try ar.print("(no branch, rebasing detached HEAD {s})", .{if (detached) |d| d.from else "(null)"});
            }
        } else if (exists(io, dir, "BISECT_LOG")) {
            const from = try l.stateBranch("BISECT_START");
            text = try ar.print("(no branch, bisect started on {s})", .{from orelse "(null)"});
        } else if (detached) |d| {
            text = try ar.print("(HEAD detached {s} {s})", .{ if (d.at) "at" else "from", d.from });
        }
        l.head_description = text;
        return text;
    }

    /// git's `get_branch` for a state file.
    fn stateBranch(l: *Listing, path: []const u8) ErrorNamespace.Error!?[]const u8 {
        const bytes = l.repo.gitDirectory().readFileAlloc(l.io, path, l.a(), .limited(1 << 20)) catch return null;
        const trimmed = std.mem.trimEnd(u8, bytes, "\n");
        if (trimmed.len == 0) return null;
        if (std.mem.startsWith(u8, trimmed, "refs/heads/")) return trimmed["refs/heads/".len..];
        if (std.mem.startsWith(u8, trimmed, "refs/")) return trimmed;
        if (Oid.parse(l.repo.objectFormat(), trimmed)) |oid| {
            const value = try l.showOid(.short, oid);
            return value;
        } else |_| {}
        if (std.mem.eql(u8, trimmed, "detached HEAD")) return null;
        return trimmed;
    }

    /// git's `wt_status_get_detached_from`: where the last checkout that
    /// detached `HEAD` came from, and whether `HEAD` is still there.
    fn detachedFrom(l: *Listing) ErrorNamespace.Error!?struct { from: []const u8, at: bool } {
        var log = l.repo.readLog(l.io, "HEAD") catch return null;
        defer log.deinit();
        var i = log.entries.len;
        while (i > 0) {
            i -= 1;
            const entry = log.entries[i];
            const prefix = "checkout: moving from ";
            if (!std.mem.startsWith(u8, entry.message, prefix)) continue;
            const after = entry.message[prefix.len..];
            const to = std.mem.find(u8, after, " to ") orelse continue;
            var target = after[to + 4 ..];
            if (std.mem.findScalar(u8, target, '\n')) |nl| target = target[0..nl];
            const noid = entry.new;
            if (std.mem.eql(u8, target, "HEAD")) target = try l.showOid(.short, noid);
            target = try l.a().dupe(u8, target);
            var from: []const u8 = undefined;
            const found = try l.dwimRef(target);
            var matched = false;
            if (found.count == 1) {
                if (found.oid.?.eql(noid)) {
                    matched = true;
                } else if (try l.peelToCommit(found.oid.?)) |c| {
                    matched = c.eql(noid);
                }
            }
            if (matched) {
                from = found.ref;
                if (std.mem.startsWith(u8, from, "refs/tags/")) {
                    from = from["refs/tags/".len..];
                } else if (std.mem.startsWith(u8, from, "refs/remotes/")) {
                    from = from["refs/remotes/".len..];
                }
            } else from = try l.showOid(.short, noid);
            var at = false;
            if (try l.repo.refStore().resolve(l.gpa, l.io, "HEAD")) |head| {
                defer l.gpa.free(head.name);
                at = head.oid.eql(noid);
            }
            return .{ .from = from, .at = at };
        }
        return null;
    }

    // -- formatting -------------------------------------------------------

    /// git's `format_ref_array_item`: the item at `index` in `format`,
    /// appended to `out`.
    pub fn formatItem(l: *Listing, gpa: Allocator, index: usize, format: Format, out: *std.ArrayList(u8)) ErrorNamespace.Error!void {
        const item = l.items.items[index];
        try l.prepareFor(format);
        var stack: std.ArrayList(Frame) = .empty;
        defer {
            for (stack.items) |*f| f.output.deinit(gpa);
            stack.deinit(gpa);
        }
        try stack.append(gpa, .{});
        for (format.parts) |part| switch (part) {
            .literal => |text| try appendLiteral(gpa, &stack.items[stack.items.len - 1].output, text),
            .atom => |at| {
                const v = try l.atomValue(item, at);
                const atom = l.atoms.items[at];
                try handle(gpa, &stack, v, atom, format.quote);
            },
        };
        if (stack.items.len != 1) return error.UnbalancedBlock;
        try out.appendSlice(gpa, stack.items[0].output.items);
    }

    fn prepareFor(l: *Listing, format: Format) ErrorNamespace.Error!void {
        for (format.parts) |part| switch (part) {
            .atom => |at| switch (l.atoms.items[at].kind) {
                .@"ahead-behind", .@"is-base" => return l.prepare(),
                else => {},
            },
            else => {},
        };
    }

    /// Errors from `write`.
    pub const WriteError = ErrorNamespace.Error || Io.Writer.Error;

    /// git's `print_formatted_ref_array`: every item (or the first
    /// `count`), each followed by a newline, an empty one left out under
    /// `omit_empty`.
    pub const WriteOptions = struct { count: usize = 0, omit_empty: bool = false };

    pub fn write(l: *Listing, format: Format, writer: *Io.Writer, options: WriteOptions) WriteError!void {
        const count = options.count;
        const total = if (count == 0 or l.items.items.len < count) l.items.items.len else count;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(l.gpa);
        for (0..total) |i| {
            line.clearRetainingCapacity();
            try l.formatItem(l.gpa, i, format, &line);
            if (line.items.len != 0 or !options.omit_empty) {
                try writer.writeAll(line.items);
                try writer.writeByte('\n');
            }
        }
    }
};

fn lessString(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn orderInt(o: std.math.Order) i32 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn caseOrder(x: []const u8, y: []const u8) i32 {
    const n = @min(x.len, y.len);
    for (x[0..n], y[0..n]) |cx, cy| {
        const d = @as(i32, std.ascii.toLower(cx)) - @as(i32, std.ascii.toLower(cy));
        if (d != 0) return d;
    }
    return orderInt(std.math.order(x.len, y.len));
}

fn cString(v: Value) []const u8 {
    return if (std.mem.findScalar(u8, v.s, 0)) |z| v.s[0..z] else v.s;
}

fn isDir(io: Io, dir: Io.Dir, path: []const u8) bool {
    const stat = dir.statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn exists(io: Io, dir: Io.Dir, path: []const u8) bool {
    _ = dir.statFile(io, path, .{}) catch return false;
    return true;
}

fn normalizePath(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    const copy = try gpa.dupe(u8, path);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

/// git's `apply_refspecs`: where `name` maps through the first refspec
/// that takes it, none if a negative one excludes it.
fn applyRefspecs(gpa: Allocator, specs: []const refspec.Refspec, name: []const u8) Allocator.Error!?[]const u8 {
    if (refspec.excluded(specs, name)) return null;
    for (specs) |spec| {
        if (spec.negative) continue;
        if (try spec.mapSource(gpa, name)) |mapped| return mapped;
    }
    return null;
}

const rev_parse_rules = [_][]const u8{
    "%s",
    "refs/%s",
    "refs/tags/%s",
    "refs/heads/%s",
    "refs/remotes/%s",
    "refs/remotes/%s/HEAD",
};

fn expandRule(gpa: Allocator, rule: []const u8, name: []const u8) Allocator.Error![]const u8 {
    const at = std.mem.find(u8, rule, "%s").?;
    return std.mem.concat(gpa, u8, &.{ rule[0..at], name, rule[at + 2 ..] });
}

/// git's `match_parse_rule`: the part of `name` a rule's `%s` stands for.
fn matchParseRule(name: []const u8, rule: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, rule, "%s").?;
    const before = rule[0..at];
    const after = rule[at + 2 ..];
    if (!std.mem.startsWith(u8, name, before)) return null;
    if (!std.mem.endsWith(u8, name, after)) return null;
    if (name.len < before.len + after.len) return null;
    const short = name[before.len .. name.len - after.len];
    if (short.len == 0) return null;
    return short;
}

fn componentCount(name: []const u8, len: i32) i64 {
    if (len >= 0) return len;
    var slashes: i64 = 0;
    for (name) |c| {
        if (c == '/') slashes += 1;
    }
    return slashes + len + 1;
}

fn lstripComponents(name: []const u8, len: i32) []const u8 {
    var remaining = componentCount(name, len);
    var at: usize = 0;
    while (remaining > 0) {
        if (at >= name.len) return "";
        if (name[at] == '/') remaining -= 1;
        at += 1;
    }
    return name[at..];
}

fn rstripComponents(name: []const u8, len: i32) []const u8 {
    var remaining = componentCount(name, len);
    var end = name.len;
    while (remaining > 0) {
        if (end == 0) return "";
        end -= 1;
        if (name[end] == '/') remaining -= 1;
    }
    return name[0..end];
}

/// A filter's patterns with their globs, compiled once for every ref a
/// listing asks them of.
const Globs = struct {
    texts: []const []const u8,
    globs: []const glob_mod.Glob,

    /// `texts` as `filter` matches them, compiled in `a`, which holds them.
    fn compile(a: Allocator, filter: Filter, texts: []const []const u8) Allocator.Error!Globs {
        const globs = try a.alloc(glob_mod.Glob, texts.len);
        for (texts, globs) |text, *glob| glob.* = try .compile(a, text, .{ .pathname = filter.match_as_path, .case_fold = filter.ignore_case });
        return .{ .texts = texts, .globs = globs };
    }

    /// git's `match_pattern` and `match_name_as_path`: whether `name_in` is
    /// one the patterns name, and `empty_matches` when there are none.
    fn matches(g: *const Globs, filter: Filter, name_in: []const u8, empty_matches: bool) bool {
        if (g.texts.len == 0) return empty_matches;
        if (filter.match_as_path) {
            for (g.texts, g.globs) |p, *glob| {
                if (p.len <= name_in.len and std.mem.eql(u8, name_in[0..p.len], p) and
                    (name_in.len == p.len or name_in[p.len] == '/' or (p.len > 0 and p[p.len - 1] == '/'))) return true;
                if (glob.matches(name_in)) return true;
            }
            return false;
        }
        var name = name_in;
        for ([_][]const u8{ "refs/tags/", "refs/heads/", "refs/remotes/", "refs/" }) |prefix| {
            if (std.mem.startsWith(u8, name, prefix)) {
                name = name[prefix.len..];
                break;
            }
        }
        for (g.globs) |*glob| if (glob.matches(name)) return true;
        return false;
    }
};

/// The globs a listing includes and excludes refs by.
const Patterns = struct {
    include: Globs,
    exclude: Globs,
};

/// The value of the header `key` in an object's headers.
fn headerValue(buf: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, headerBlock(buf), '\n');
    while (lines.next()) |line| {
        if (line.len > key.len and std.mem.startsWith(u8, line, key) and line[key.len] == ' ') return line[key.len + 1 ..];
    }
    return null;
}

fn headerBlock(buf: []const u8) []const u8 {
    if (std.mem.find(u8, buf, "\n\n")) |end| return buf[0..end];
    return buf;
}

/// git's `find_wholine`: the rest of the header line `who` starts.
fn findWholine(buf: []const u8, who: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (at < buf.len) {
        if (std.mem.startsWith(u8, buf[at..], who) and at + who.len < buf.len and buf[at + who.len] == ' ')
            return buf[at + who.len + 1 ..];
        const eol = std.mem.findScalarPos(u8, buf, at, '\n') orelse return null;
        at = eol + 1;
        if (at < buf.len and buf[at] == '\n') return null;
    }
    return null;
}

/// git's `copy_email`.
fn copyEmail(line: []const u8, atom: Atom) []const u8 {
    const eol = std.mem.findScalar(u8, line, '\n') orelse line.len;
    _ = eol;
    var email_at = std.mem.findScalar(u8, line, '<') orelse return "";
    if (atom.email_localpart or atom.email_trim) email_at += 1;
    const email = line[email_at..];
    var end: ?usize = null;
    if (atom.email_localpart) {
        end = std.mem.findScalar(u8, email, '@') orelse std.mem.findScalar(u8, email, '>');
    } else if (atom.email_trim) {
        end = std.mem.findScalar(u8, email, '>');
    } else {
        if (std.mem.findScalar(u8, email, '>')) |gt| end = gt + 1;
    }
    return email[0 .. end orelse return ""];
}

const Subpos = struct {
    /// From the subject to the end.
    from_sub: []const u8,
    sub: []const u8,
    body: []const u8,
    nonsig_len: usize,
    sig: []const u8,
};

/// git's `find_subpos`.
fn findSubpos(buf_in: []const u8) Subpos {
    var at: usize = 0;
    const buf = buf_in;
    while (at < buf.len and buf[at] != '\n') {
        const eol = std.mem.findScalarPos(u8, buf, at, '\n') orelse buf.len;
        at = if (eol < buf.len) eol + 1 else eol;
    }
    while (at < buf.len and buf[at] == '\n') at += 1;
    const start = at;
    const sigstart = start + parseSignedBuffer(buf[start..]);
    const sig = buf[sigstart..];
    var eol: usize = sigstart;
    if (std.mem.find(u8, buf[start..], "\n\n")) |e| {
        eol = @min(start + e, sigstart);
    } else if (std.mem.find(u8, buf[start..], "\r\n\r\n")) |e| {
        eol = @min(start + e, sigstart);
    }
    var sublen = eol - start;
    while (sublen > 0 and (buf[start + sublen - 1] == '\n' or buf[start + sublen - 1] == '\r')) sublen -= 1;
    var body_at = eol;
    while (body_at < buf.len and (buf[body_at] == '\n' or buf[body_at] == '\r')) body_at += 1;
    return .{
        .from_sub = buf[start..],
        .sub = buf[start .. start + sublen],
        .body = buf[body_at..],
        .nonsig_len = if (sigstart > body_at) sigstart - body_at else 0,
        .sig = sig,
    };
}

/// git's `parse_signed_buffer`: where the last line that starts a
/// signature begins, or the length when none does.
fn parseSignedBuffer(buf: []const u8) usize {
    var len: usize = 0;
    var match = buf.len;
    while (len < buf.len) {
        if (signing.Format.of(buf[len..]) != null) match = len;
        const eol = std.mem.findScalarPos(u8, buf, len, '\n');
        len = if (eol) |e| e + 1 else buf.len;
    }
    return match;
}

/// git's `append_literal`: `%%` is one `%`, `%xx` a byte.
fn appendLiteral(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    var cp: usize = 0;
    while (cp < text.len) {
        if (text[cp] == '%') {
            if (cp + 1 < text.len and text[cp + 1] == '%') {
                cp += 1;
            } else if (percent.escapeAt(text, cp)) |byte| {
                try out.append(gpa, byte);
                cp += 3;
                continue;
            }
        }
        try out.append(gpa, text[cp]);
        cp += 1;
    }
}

const Frame = struct {
    output: std.ArrayList(u8) = .empty,
    at_end: enum { none, @"align", if_then_else } = .none,
    @"align": Align = .{ .position = .left, .width = 0 },
    compare: Compare = .none,
    compare_with: []const u8 = "",
    then_seen: bool = false,
    else_seen: bool = false,
    satisfied: bool = false,
    /// An `%(else)` frame: its condition lives in the frame below.
    is_else: bool = false,
};

fn quoteInto(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8, sized: bool, quote: Quote) Allocator.Error!void {
    const s = if (sized and quote == .perl) text else if (std.mem.findScalar(u8, text, 0)) |z| text[0..z] else text;
    switch (quote) {
        .none => try out.appendSlice(gpa, if (sized) text else s),
        .shell => {
            try out.append(gpa, '\'');
            for (s) |c| {
                if (c == '\'' or c == '!') {
                    try out.appendSlice(gpa, "'\\");
                    try out.append(gpa, c);
                    try out.append(gpa, '\'');
                } else try out.append(gpa, c);
            }
            try out.append(gpa, '\'');
        },
        .perl => {
            try out.append(gpa, '\'');
            for (s) |c| {
                if (c == '\'' or c == '\\') try out.append(gpa, '\\');
                try out.append(gpa, c);
            }
            try out.append(gpa, '\'');
        },
        .python => {
            try out.append(gpa, '\'');
            for (s) |c| {
                if (c == '\n') {
                    try out.appendSlice(gpa, "\\n");
                    continue;
                }
                if (c == '\'' or c == '\\') try out.append(gpa, '\\');
                try out.append(gpa, c);
            }
            try out.append(gpa, '\'');
        },
        .tcl => {
            try out.append(gpa, '"');
            for (s) |c| switch (c) {
                '[', ']', '{', '}', '$', '\\', '"' => {
                    try out.append(gpa, '\\');
                    try out.append(gpa, c);
                },
                0x0c => try out.appendSlice(gpa, "\\f"),
                '\r' => try out.appendSlice(gpa, "\\r"),
                '\n' => try out.appendSlice(gpa, "\\n"),
                '\t' => try out.appendSlice(gpa, "\\t"),
                0x0b => try out.appendSlice(gpa, "\\v"),
                else => try out.append(gpa, c),
            };
            try out.append(gpa, '"');
        },
    }
}

fn isEmpty(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isWhitespace(c)) return false;
    return true;
}

fn alignText(gpa: Allocator, a: Align, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const s = if (std.mem.findScalar(u8, text, 0)) |z| text[0..z] else text;
    const display = unicodewidth.strWidth(s);
    if (display >= a.width) {
        try out.appendSlice(gpa, s);
        return out.toOwnedSlice(gpa);
    }
    const pad = a.width - display;
    switch (a.position) {
        .left => {
            try out.appendSlice(gpa, s);
            try out.appendNTimes(gpa, ' ', pad);
        },
        .right => {
            try out.appendNTimes(gpa, ' ', pad);
            try out.appendSlice(gpa, s);
        },
        .middle => {
            const left = pad / 2;
            try out.appendNTimes(gpa, ' ', left);
            try out.appendSlice(gpa, s);
            try out.appendNTimes(gpa, ' ', pad - left);
        },
    }
    return out.toOwnedSlice(gpa);
}

/// One atom's value through the formatting stack: git's handlers.
fn handle(gpa: Allocator, stack: *std.ArrayList(Frame), v: Value, atom: Atom, quote: Quote) Error!void {
    const top = &stack.items[stack.items.len - 1];
    switch (v.handler) {
        .append => {
            if (stack.items.len == 1) {
                try quoteInto(gpa, &top.output, v.s, v.sized, quote);
            } else {
                try top.output.appendSlice(gpa, if (v.sized) v.s else cString(v));
            }
        },
        .@"align" => try stack.append(gpa, .{ .at_end = .@"align", .@"align" = atom.@"align" }),
        .@"if" => try stack.append(gpa, .{ .at_end = .if_then_else, .compare = atom.compare, .compare_with = atom.compare_with }),
        .then => {
            if (top.at_end != .if_then_else or top.is_else) return error.UnbalancedBlock;
            if (top.then_seen or top.else_seen) return error.UnbalancedBlock;
            top.then_seen = true;
            switch (top.compare) {
                .equal => top.satisfied = std.mem.eql(u8, top.compare_with, top.output.items),
                .unequal => top.satisfied = !std.mem.eql(u8, top.compare_with, top.output.items),
                .none => top.satisfied = top.output.items.len != 0 and !isEmpty(top.output.items),
            }
            top.output.clearRetainingCapacity();
        },
        .@"else" => {
            if (top.at_end != .if_then_else or top.is_else) return error.UnbalancedBlock;
            if (!top.then_seen) return error.UnbalancedBlock;
            if (top.else_seen) return error.UnbalancedBlock;
            top.else_seen = true;
            try stack.append(gpa, .{ .at_end = .if_then_else, .is_else = true });
        },
        .end => {
            if (top.at_end == .none) return error.UnbalancedBlock;
            switch (top.at_end) {
                .@"align" => {
                    const aligned = try alignText(gpa, top.@"align", top.output.items);
                    top.output.deinit(gpa);
                    top.output = .fromOwnedSlice(aligned);
                },
                .if_then_else => {
                    if (top.is_else) {
                        // the frame below holds the condition and the then branch
                        const cond = &stack.items[stack.items.len - 2];
                        if (!cond.then_seen) return error.UnbalancedBlock;
                        var else_frame = stack.pop().?;
                        if (cond.satisfied) {
                            else_frame.output.deinit(gpa);
                        } else {
                            cond.output.deinit(gpa);
                            cond.output = else_frame.output;
                        }
                    } else {
                        if (!top.then_seen) return error.UnbalancedBlock;
                        if (!top.satisfied) top.output.clearRetainingCapacity();
                    }
                },
                .none => unreachable,
            }
            // quoting happens at the outermost block's end
            var current = stack.pop().?;
            defer current.output.deinit(gpa);
            const below = &stack.items[stack.items.len - 1];
            if (stack.items.len == 1) {
                try quoteInto(gpa, &below.output, current.output.items, false, quote);
            } else {
                try below.output.appendSlice(gpa, current.output.items);
            }
        },
    }
}

// ---------------------------------------------------------------------------
// what the commands do
// ---------------------------------------------------------------------------

/// What `listRefs` is asked: a command's filter, sort keys and format.
pub const Options = struct {
    filter: Filter = .{},
    /// The keys, the last compared first. Empty sorts by name.
    sort: []const SortKey = &.{.{ .atom = "refname" }},
    sort_options: SortOptions = .{},
    /// `--format`; `for-each-ref`'s default when `null`.
    format: ?[]const u8 = null,
    quote: Quote = .none,
    /// `--count`: at most this many; zero is all.
    count: usize = 0,
    /// `--omit-empty`.
    omit_empty: bool = false,
    context: Context = .{},
};

/// `git for-each-ref`'s default format.
pub const for_each_ref_format = "%(objectname) %(objecttype)\t%(refname)";

/// `git tag --list`'s default format, or with `-n<lines>` the one that
/// shows that many lines of each message.
pub fn tagFormat(gpa: Allocator, lines: u32) Allocator.Error![]u8 {
    if (lines == 0) return gpa.dupe(u8, "%(refname:lstrip=2)");
    return gpa.print("%(align:15)%(refname:lstrip=2)%(end) %(contents:lines={d})", .{lines});
}

/// What `git branch` shows: `verbose` 0, 1 (`-v`) or 2 (`-vv`), `abbrev`
/// the digits of an object name (`null` for git's default, zero for the
/// whole name), and whether only remote-tracking branches are listed.
pub const BranchOptions = struct {
    verbose: u2 = 0,
    abbrev: ?u32 = null,
    remotes_only: bool = false,
};

/// `git branch`'s format for the refs `l` holds: git's `build_format`,
/// with colour off. The text is `gpa`'s.
pub fn branchFormat(gpa: Allocator, l: *Listing, options: BranchOptions) Error![]u8 {
    const remote_prefix = if (options.remotes_only) "" else "remotes/";
    var local: std.ArrayList(u8) = .empty;
    defer local.deinit(gpa);
    var remote: std.ArrayList(u8) = .empty;
    defer remote.deinit(gpa);
    try local.appendSlice(gpa, "%(if)%(HEAD)%(then)* %(else)%(if)%(worktreepath)%(then)+ %(else)  %(end)%(end)");
    try remote.appendSlice(gpa, "  ");
    var quoted_prefix: std.ArrayList(u8) = .empty;
    defer quoted_prefix.deinit(gpa);
    for (remote_prefix) |c| {
        if (c == '%') try quoted_prefix.append(gpa, '%');
        try quoted_prefix.append(gpa, c);
    }
    if (options.verbose > 0) {
        var maxwidth: usize = 0;
        for (l.items.items) |item| {
            var desc = item.name;
            if (std.mem.startsWith(u8, desc, "refs/heads/")) desc = desc["refs/heads/".len..];
            if (std.mem.startsWith(u8, desc, "refs/remotes/")) desc = desc["refs/remotes/".len..];
            var w = if (item.kind == .detached_head) unicodewidth.strWidth(try l.headDescription()) else unicodewidth.strWidth(desc);
            if (item.kind == .remote) w += remote_prefix.len;
            maxwidth = @max(maxwidth, w);
        }
        const obname = if (options.abbrev) |n|
            (if (n == 0) try gpa.dupe(u8, "%(objectname)") else try gpa.print("%(objectname:short={d})", .{n}))
        else
            try gpa.dupe(u8, "%(objectname:short)");
        defer gpa.free(obname);
        try local.print(gpa, "%(align:{d},left)%(refname:lstrip=2)%(end) {s} ", .{ maxwidth, obname });
        if (options.verbose > 1) {
            try local.appendSlice(gpa, "%(if:notequals=*)%(HEAD)%(then)%(if)%(worktreepath)%(then)(%(worktreepath)) %(end)%(end)");
            try local.appendSlice(gpa, "%(if)%(upstream)%(then)[%(upstream:short)%(if)%(upstream:track)%(then): %(upstream:track,nobracket)%(end)] %(end)%(contents:subject)");
        } else {
            try local.appendSlice(gpa, "%(if)%(upstream:track)%(then)%(upstream:track) %(end)%(contents:subject)");
        }
        try remote.print(gpa, "%(align:{d},left){s}%(refname:lstrip=2)%(end)%(if)%(symref)%(then) -> %(symref:short)%(else) {s} %(contents:subject)%(end)", .{ maxwidth, quoted_prefix.items, obname });
    } else {
        try local.appendSlice(gpa, "%(refname:lstrip=2)%(if)%(symref)%(then) -> %(symref:short)%(end)");
        try remote.print(gpa, "{s}%(refname:lstrip=2)%(if)%(symref)%(then) -> %(symref:short)%(end)", .{quoted_prefix.items});
    }
    return gpa.print("%(if:notequals=refs/remotes)%(refname:rstrip=-2)%(then){s}%(else){s}%(end)", .{ local.items, remote.items });
}

/// Errors from `listRefs`.
pub const ListRefsError = Error || Io.Writer.Error;

/// Filter, sort and write as `git for-each-ref` does.
pub fn listRefs(gpa: Allocator, io: Io, repo: *Repository, options: Options, writer: *Io.Writer) ListRefsError!void {
    var l = Listing.init(gpa, io, repo, options.context);
    defer l.deinit();
    const format = try l.parseFormat(options.format orelse for_each_ref_format, options.quote);
    try l.collect(options.filter);
    try l.sort(options.sort, options.sort_options);
    try l.write(format, writer, .{ .count = options.count, .omit_empty = options.omit_empty });
}

/// Which branches `listBranches` lists: `git branch`, `-r` or `-a`.
pub const Branches = enum { local, remote, all };

/// What `listBranches` is asked: `git branch --list`'s options.
pub const BranchListOptions = struct {
    which: Branches = .local,
    /// The globs, matched after `refs/heads/` or `refs/remotes/`.
    patterns: []const []const u8 = &.{},
    /// `-v` once or twice.
    verbose: u2 = 0,
    /// `--abbrev=<n>`; zero is `--no-abbrev`.
    abbrev: ?u32 = null,
    /// `--sort` keys, after `branch.sort`'s.
    sort: []const SortKey = &.{},
    /// `--no-sort`.
    no_sort: bool = false,
    /// `-i`.
    ignore_case: bool = false,
    contains: []const Oid = &.{},
    no_contains: []const Oid = &.{},
    merged: []const Oid = &.{},
    no_merged: []const Oid = &.{},
    points_at: []const Oid = &.{},
    /// `--format`; git's own when `null`.
    format: ?[]const u8 = null,
    omit_empty: bool = false,
    context: Context = .{},
};

/// Errors from `listBranches`.
pub const ListBranchesError = Error || Io.Writer.Error;

/// List branches as `git branch --list` does, colour off.
pub fn listBranches(gpa: Allocator, io: Io, repo: *Repository, options: BranchListOptions, writer: *Io.Writer) ListBranchesError!void {
    var l = Listing.init(gpa, io, repo, options.context);
    defer l.deinit();
    var kinds: Kinds = switch (options.which) {
        .local => .{ .branches = true },
        .remote => .{ .remotes = true },
        .all => .{ .branches = true, .remotes = true },
    };
    // a detached HEAD is listed among the branches
    if (kinds.branches) {
        if (try repo.refStore().read(gpa, io, "HEAD")) |head| switch (head) {
            .direct => kinds.detached_head = true,
            .symbolic => |name| gpa.free(name),
        };
    }
    try l.collect(.{
        .kinds = kinds,
        .patterns = options.patterns,
        .match_as_path = false,
        .ignore_case = options.ignore_case,
        .points_at = options.points_at,
        .contains = options.contains,
        .no_contains = options.no_contains,
        .merged = options.merged,
        .no_merged = options.no_merged,
        .commits_only = options.verbose > 0,
    });
    const text = options.format orelse try branchFormat(l.a(), &l, .{
        .verbose = options.verbose,
        .abbrev = options.abbrev,
        .remotes_only = options.which == .remote,
    });
    const format = try l.parseFormat(text, .none);
    if (!options.no_sort) {
        const configured = try configuredSort(gpa, repo.configuration(), "branch.sort");
        defer gpa.free(configured);
        var keys: std.ArrayList(SortKey) = .empty;
        try keys.appendSlice(l.a(), configured);
        try keys.appendSlice(l.a(), options.sort);
        try l.sort(keys.items, .{ .ignore_case = options.ignore_case, .detached_head_first = true });
    }
    try l.write(format, writer, .{ .count = 0, .omit_empty = options.omit_empty });
}

/// What `listTags` is asked: `git tag --list`'s options.
pub const TagListOptions = struct {
    /// The globs, matched after `refs/tags/`.
    patterns: []const []const u8 = &.{},
    /// `-n<lines>`: that many lines of each message.
    lines: u32 = 0,
    /// `--sort` keys, after `tag.sort`'s.
    sort: []const SortKey = &.{},
    no_sort: bool = false,
    ignore_case: bool = false,
    contains: []const Oid = &.{},
    no_contains: []const Oid = &.{},
    merged: []const Oid = &.{},
    no_merged: []const Oid = &.{},
    points_at: []const Oid = &.{},
    format: ?[]const u8 = null,
    omit_empty: bool = false,
    context: Context = .{},
};

/// Errors from `listTags`.
pub const ListTagsError = Error || Io.Writer.Error;

/// List tags as `git tag --list` does.
pub fn listTags(gpa: Allocator, io: Io, repo: *Repository, options: TagListOptions, writer: *Io.Writer) ListTagsError!void {
    var l = Listing.init(gpa, io, repo, options.context);
    defer l.deinit();
    const text = options.format orelse try tagFormat(l.a(), options.lines);
    const format = try l.parseFormat(text, .none);
    try l.collect(.{
        .kinds = .{ .tags = true },
        .patterns = options.patterns,
        .match_as_path = false,
        .ignore_case = options.ignore_case,
        .points_at = options.points_at,
        .contains = options.contains,
        .no_contains = options.no_contains,
        .merged = options.merged,
        .no_merged = options.no_merged,
    });
    if (!options.no_sort) {
        const configured = try configuredSort(gpa, repo.configuration(), "tag.sort");
        defer gpa.free(configured);
        var keys: std.ArrayList(SortKey) = .empty;
        try keys.appendSlice(l.a(), configured);
        try keys.appendSlice(l.a(), options.sort);
        try l.sort(keys.items, .{ .ignore_case = options.ignore_case });
    }
    try l.write(format, writer, .{ .count = 0, .omit_empty = options.omit_empty });
}

test "version sort orders numbers by value and prerelease suffixes before their release" {
    try std.testing.expect(versioncmp("v1.2", "v1.10", &.{}) < 0);
    try std.testing.expect(versioncmp("v1.10", "v1.9", &.{}) > 0);
    try std.testing.expect(versioncmp("a", "a", &.{}) == 0);
    try std.testing.expect(versioncmp("v1.0-rc1", "v1.0", &.{}) > 0);
    try std.testing.expect(versioncmp("v1.0-rc1", "v1.0", &.{"-rc"}) < 0);
    try std.testing.expect(versioncmp("v1.0-rc1", "v1.0-rc2", &.{"-rc"}) < 0);
    try std.testing.expect(versioncmp("000", "00", &.{}) < 0);
    try std.testing.expect(versioncmp("1.010", "1.09", &.{}) < 0);
}
