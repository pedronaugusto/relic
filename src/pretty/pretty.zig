//! git's `--format` placeholders for one commit: what `git log
//! --format=...` prints and what `git archive` substitutes for
//! `$Format:...$` in a file marked `export-subst`.
//!
//! Names, emails, dates in git's formats, object names whole and
//! abbreviated, subject, body, the `%+`, `%-` and `% ` modifiers, `%n`,
//! `%%` and `%xNN`, each as git's `pretty.c` writes it; an unknown
//! placeholder is written as it stands, as git writes it. The mailmap's
//! names (`%aN`, `%aE`, `%aL`), decorations (`%d`, `%D`, `%(decorate)`),
//! notes (`%N`) and signatures (`%G?` and the rest) come from what the
//! `Context` holds, and `%(trailers)` with every option reads trailers as
//! its `trailers` settings say. A commit in another encoding is converted
//! to UTF-8 first and the output written in `Context.output_encoding`, as
//! git's `format_commit_message` does. Colour (`%C(...)`, `%C(auto)`, the
//! object names and decorations it paints) is written as `Context.colors`
//! says, as a log writes it under `--color`. Dates are git's `show_date`, `%ad` and
//! `%cd` in `Context.date_mode`, a relative or human one by `Context.clock`.
//! What needs more — `%(describe)`, wrapping and padding — is refused as
//! `error.UnsupportedPlaceholder`.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const ctype = @import("../text.zig").ctype;
const percent = @import("../text.zig").percent;
const encoding = @import("../text.zig").encoding;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const abbrev = @import("../odb/abbrev.zig");
const date = @import("../text.zig").date;
const mailfmt = @import("../mail/format.zig");
const decimal = @import("../text.zig").decimal;
const repo_mod = @import("../repo/repo.zig");
const refs_mod = @import("../refs/refs.zig");
const shallow = @import("../walk/shallow.zig");
const signing = @import("../object/signing.zig");
const trailer = @import("../object/trailer.zig");
const ref_names = @import("../names.zig").ref;
const mailmap_mod = @import("../rev_walk/mailmap.zig");
const color = @import("../config/color.zig");
const config_mod = @import("../config/config.zig");
const diff_colors = @import("../diff/paint.zig");
const glob = @import("../text.zig").glob;

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from formatting.
pub const Error = error{
    /// A placeholder git understands that this does not produce.
    UnsupportedPlaceholder,
    /// A signature placeholder for a signed commit, with no `signer` to
    /// check it.
    SignatureNeedsSigner,
    NotACommit,
    /// A commit's `encoding`, or the output's, names a character set
    /// `encoding.Charset` does not convert, where git converts it with
    /// iconv.
    UnsupportedEncoding,
    /// A `%C(...)` whose colour does not parse, where git dies ("unable
    /// to parse --pretty format"). git reads it only when it writes it.
    InvalidColor,
} || signing.Error || odb_mod.Error || object.ParseError || date.ShowError || Allocator.Error;

/// What formatting needs besides the commit.
pub const Context = struct {
    /// The digits `%h`, `%t` and `%p` start from before they grow to be
    /// unique: `core.abbrev`'s length.
    abbrev_len: usize = abbrev.fallback,
    /// Who `%aN`, `%aE`, `%aL` and the committer's show a person as: git
    /// reads the repository's mailmap (`Mailmap.load`) for every format.
    /// `null` maps no one.
    mailmap: ?*const mailmap_mod.Mailmap = null,
    /// The refs `%d`, `%D` and `%(decorate)` name, as `Decorations.load`
    /// finds them. `null` names none.
    decorations: ?*const Decorations = null,
    /// What `%N` writes: the commit's notes as `git log` hands them to a
    /// format. `null` writes `%N` as it stands, as `git archive` does.
    notes: ?[]const u8 = null,
    /// What checks a signature for `%G?`, `%GG`, `%GS`, `%GK`, `%GF`,
    /// `%GP` and `%GT`. A commit with no signature needs none.
    signer: ?*signing.Signer = null,
    /// How `%(trailers)` reads trailers: git's defaults unless given;
    /// `commit.message.trailerSettings` reads a repository's.
    trailers: trailer.Settings = .{},
    /// The encoding the output is written in: `git log` and `git
    /// shortlog` give `commit.message.logOutputEncoding`. `null`, git's
    /// unset, writes it in the commit's own `encoding`, as `git archive`
    /// and a merge message's list of commits do. The placeholders are
    /// expanded in UTF-8 either way, the commit converted first.
    output_encoding: ?[]const u8 = null,
    /// The colours of a log written in colour, `null` for one written
    /// without: what `Colors.configured` gives. `%C(...)` writes its
    /// colour only where there are colours, unless it says `always`.
    colors: ?*const Colors = null,
    /// How `%ad` and `%cd` show a date: `--date`, or what
    /// `configuredDateMode` reads from `log.date`.
    date_mode: date.Mode = .{},
    /// The time now and the machine's zone, for a relative or human date
    /// (`%ar`, `%ah`) or a `-local` mode. Without them such a date is
    /// `error.DateNeedsClock`.
    clock: date.Clock = .{},
    /// Where the commit stands in a numbered list, for `%(count)` and
    /// `%(total)`: git's cover letter lists them so. `null` refuses both,
    /// as git dies ("not supported by this command").
    numbered: ?Numbered = null,

    pub const Numbered = struct { nr: usize, total: usize };
};

/// What a log format colours with, as `git log --color` does: the
/// object name `%H` and `%h` show and a decoration's punctuation in
/// `color.diff.commit`, each decoration in its `color.decorate.<slot>`;
/// a log's signature lines in `color.diff.frag` when good and
/// `color.diff.whitespace` when not.
pub const Colors = struct {
    commit: color.Color = color.yellow,
    frag: color.Color = color.cyan,
    whitespace: color.Color = color.bg_red,
    branch: color.Color = color.bold_green,
    remote_branch: color.Color = color.bold_red,
    tag: color.Color = color.bold_yellow,
    stash: color.Color = color.bold_magenta,
    head: color.Color = color.bold_cyan,
    grafted: color.Color = color.bold_blue,

    const Decorate = struct {
        branch: color.Color = color.bold_green,
        remote_branch: color.Color = color.bold_red,
        tag: color.Color = color.bold_yellow,
        stash: color.Color = color.bold_magenta,
        head: color.Color = color.bold_cyan,
        grafted: color.Color = color.bold_blue,
    };

    /// git's `color_decorate_slots`.
    const decorate_names = [_]struct { []const u8, std.meta.FieldEnum(Decorate) }{
        .{ "branch", .branch }, .{ "remoteBranch", .remote_branch }, .{ "tag", .tag },
        .{ "stash", .stash },   .{ "HEAD", .head },                  .{ "grafted", .grafted },
    };

    /// git's defaults under `color.decorate.<slot>` and the diff's slots
    /// (`diff.Colors.read`), each value read as `git log` reads it.
    pub fn read(config: *const config_mod.Config) color.Error!Colors {
        var slots: Decorate = .{};
        try color.readSlots(Decorate, &slots, config, &decorate_names, .{ .sections = &.{.{ .section = "color", .subsection = "decorate" }} });
        const diff = try diff_colors.Colors.read(config);
        var out: Colors = .{ .commit = diff.commit, .frag = diff.frag, .whitespace = diff.whitespace };
        inline for (@typeInfo(Decorate).@"struct".field_names) |name| @field(out, name) = @field(slots, name);
        return out;
    }

    /// The colours `output` asks for: `null` where git writes a log
    /// without colour, as the diff's `color.diff` (or `diff.color`) and
    /// `color.ui` decide, which is what `git log` colours by.
    pub fn configured(config: ?*const config_mod.Config, output: color.Output) color.Error!?Colors {
        if (!try color.wanted(config, &.{ "color.diff", "diff.color" }, output)) return null;
        return if (config) |c| try read(c) else .{};
    }

    /// git's `decorate_get_color`: a ref of no kind is in the reset.
    fn of(c: *const Colors, kind: Decorations.Kind) []const u8 {
        return switch (kind) {
            .none => color.reset,
            .local => c.branch.bytes(),
            .remote => c.remote_branch.bytes(),
            .tag => c.tag.bytes(),
            .stash => c.stash.bytes(),
            .head => c.head.bytes(),
            .grafted => c.grafted.bytes(),
        };
    }
};

/// A commit's bytes in an output encoding: what `reencodeCommit` gives.
pub const Reencoded = struct {
    /// The object's bytes, converted, its `encoding` header naming the
    /// output's encoding or, for UTF-8, left out; the bytes as they are
    /// where there was nothing to convert or the conversion stopped.
    bytes: []const u8,
    /// The commit's own `encoding` header, `null` for none.
    encoding: ?[]const u8,
};

/// git's `logmsg_reencode`: commit object `raw` with its message and
/// headers converted from the commit's `encoding` (UTF-8 when it names
/// none) into `output`. `null` or an empty `output` converts nothing.
/// Text that will not convert is kept as it is, as git keeps it; a
/// character set `encoding.Charset` does not name is
/// `error.UnsupportedEncoding`. The bytes are `a`'s or `raw`.
pub fn reencodeCommit(a: Allocator, raw: []const u8, output: ?[]const u8) encoding.ReencodeError!Reencoded {
    const own: ?[]const u8 = if (object.findHeader(raw, 0, "encoding")) |h| raw[h.start..h.end] else null;
    const want = output orelse return .{ .bytes = raw, .encoding = own };
    if (want.len == 0) return .{ .bytes = raw, .encoding = own };
    const converted: []const u8 = if (encoding.same(own orelse "UTF-8", want))
        (if (own == null) return .{ .bytes = raw, .encoding = null } else raw)
    else
        // git converts the object as a C string: up to a NUL
        try encoding.reencode(a, cstr(raw), want, own orelse "UTF-8") orelse return .{ .bytes = raw, .encoding = own };
    // git's `replace_encoding_header`
    const h = object.findHeader(converted, 0, "encoding") orelse return .{ .bytes = converted, .encoding = own };
    const line_start = h.start - "encoding ".len;
    const line_end = if (h.end < converted.len) h.end + 1 else return .{ .bytes = converted, .encoding = own };
    const replacement: []const u8 = if (encoding.isUtf8(want)) "" else try std.mem.concat(a, u8, &.{ "encoding ", want, "\n" });
    return .{ .bytes = try std.mem.concat(a, u8, &.{ converted[0..line_start], replacement, converted[line_end..] }), .encoding = own };
}

/// The refs that point at each object, as git loads them for a format:
/// every ref, then `HEAD`, then the shallow commits as `grafted`; a tag
/// names what it points at too, and `refs/replace/<oid>` marks `<oid>`
/// as `replaced`. Each object's names come newest first, as git lists
/// them.
pub const Decorations = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    by_object: Oid.Map(*const Decoration) = .empty,
    /// The ref `HEAD` points at, written `HEAD -> <branch>` where both
    /// decorate one commit.
    head_branch: ?[]const u8 = null,
    style: Style = .short,

    /// git's `decoration_type`.
    pub const Kind = enum { none, local, remote, tag, stash, head, grafted };

    pub const Decoration = struct {
        kind: Kind,
        /// The whole ref name.
        name: []const u8,
        next: ?*const Decoration,
    };

    pub const LoadError = refs_mod.ReadError || odb_mod.Error || object.ParseError || shallow.ReadError || Allocator.Error;

    /// Which refs decorate: git's `decoration_filter`. A ref an `exclude`
    /// pattern matches does not; else, where there are `include`
    /// patterns, only a ref one of them matches does; else a ref an
    /// `exclude_config` pattern matches does not. A pattern with no glob
    /// character matches the ref it names and the refs under it; one with
    /// a glob character is matched against the whole name. A pattern that
    /// starts with neither `refs/` nor is `HEAD` is under `refs/`.
    pub const Filter = struct {
        /// `--decorate-refs`.
        include: []const []const u8 = &.{},
        /// `--decorate-refs-exclude`.
        exclude: []const []const u8 = &.{},
        /// `log.excludeDecoration`.
        exclude_config: []const []const u8 = &.{},

        /// What `git log` asks for besides the configuration.
        pub const Given = struct {
            include: []const []const u8 = &.{},
            exclude: []const []const u8 = &.{},
            /// `--clear-decorations`: the patterns given before it gone,
            /// and every ref decorates where nothing else says otherwise.
            clear: bool = false,
        };

        /// git log's filter, as its `set_default_decoration_filter` makes
        /// it: `given`, `log.excludeDecoration` (every value; a bare one
        /// makes git drop them all), and where none of them say anything
        /// and neither `clear` nor `log.initialDecorationSet=all` asks for
        /// every ref, only the namespaces git decorates by default: `HEAD`,
        /// branches, tags, remote-tracking branches, the stash and
        /// replaced objects. The lists are `arena`'s.
        pub fn log(arena: Allocator, config: *const config_mod.Config, given: Given) Allocator.Error!Filter {
            var out: Filter = .{ .include = given.include, .exclude = given.exclude };
            var excluded: std.ArrayList([]const u8) = .empty;
            var it = config.iterate(&.{"log.excludedecoration"});
            while (it.next()) |entry| {
                const value = entry.value orelse {
                    excluded.clearRetainingCapacity();
                    break;
                };
                try excluded.append(arena, value);
            }
            out.exclude_config = excluded.items;
            var all = given.clear;
            if (!all) if (config.find("log.initialdecorationset")) |entry| {
                all = entry.value != null and std.mem.eql(u8, entry.value.?, "all");
            };
            if (all or out.include.len != 0 or out.exclude.len != 0 or out.exclude_config.len != 0) return out;
            out.include = &default_namespaces;
            return out;
        }

        /// git's `ref_namespace` entries that have a decoration.
        const default_namespaces = [_][]const u8{ "HEAD", "refs/heads/", "refs/tags/", "refs/remotes/", ref_names.stash, "refs/replace/" };
    };

    /// A filter's pattern as git's `normalize_glob_ref` leaves it.
    const Pattern = struct {
        text: []const u8,
        /// No glob character: the name and what is under it.
        prefix: bool,

        fn init(a: Allocator, pattern: []const u8) Allocator.Error!Pattern {
            const under = !std.mem.startsWith(u8, pattern, "refs/") and !std.mem.eql(u8, pattern, "HEAD");
            var text = try std.mem.concat(a, u8, &.{ if (under) "refs/" else "", pattern });
            if (std.mem.endsWith(u8, text, "/")) text = text[0 .. text.len - 1];
            var plain = true;
            for (pattern) |c| if (c == '*' or c == '?' or c == '[' or c == '\\') {
                plain = false;
            };
            return .{ .text = text, .prefix = plain };
        }

        /// git's `match_ref_pattern`.
        fn matches(p: Pattern, gpa: Allocator, name: []const u8) Allocator.Error!bool {
            if (!p.prefix) return glob.matches(gpa, p.text, name, .{ .pathname = false });
            if (!std.mem.startsWith(u8, name, p.text)) return false;
            return name.len == p.text.len or name[p.text.len] == '/';
        }
    };

    /// A filter with its patterns normalized.
    const Patterns = struct {
        include: []Pattern,
        exclude: []Pattern,
        exclude_config: []Pattern,

        fn init(a: Allocator, filter: *const Filter) Allocator.Error!Patterns {
            return .{ .include = try all(a, filter.include), .exclude = try all(a, filter.exclude), .exclude_config = try all(a, filter.exclude_config) };
        }

        fn all(a: Allocator, patterns: []const []const u8) Allocator.Error![]Pattern {
            const out = try a.alloc(Pattern, patterns.len);
            for (patterns, out) |text, *p| p.* = try .init(a, text);
            return out;
        }

        /// git's `ref_filter_match`.
        fn admits(ps: *const Patterns, gpa: Allocator, name: []const u8) Allocator.Error!bool {
            for (ps.exclude) |p| if (try p.matches(gpa, name)) return false;
            if (ps.include.len != 0) {
                for (ps.include) |p| if (try p.matches(gpa, name)) return true;
                return false;
            }
            for (ps.exclude_config) |p| if (try p.matches(gpa, name)) return false;
            return true;
        }
    };

    /// How a decoration names a ref: git's `DECORATE_SHORT_REFS`, a branch,
    /// tag or remote-tracking branch by its short name, or
    /// `DECORATE_FULL_REFS`, every ref whole.
    pub const Style = enum { short, full };

    /// `log.decorate`: `full` names refs whole; anything else, or nothing,
    /// short, as git's `%d` loads them where the log shows none.
    pub fn configuredStyle(config: *const config_mod.Config) Style {
        const value = config.get("log.decorate") orelse return .short;
        return if (std.mem.eql(u8, value, "full")) .full else .short;
    }

    /// What `load` reads.
    pub const LoadOptions = struct {
        /// The refs that decorate; `null` admits every ref, as `git
        /// archive` loads them.
        filter: ?*const Filter = null,
        style: Style = .short,
    };

    /// git's `load_ref_decorations`: every ref `options.filter` admits,
    /// `HEAD` included, and the grafts.
    pub fn load(gpa: Allocator, io: Io, repo: *Repository, options: LoadOptions) LoadError!Decorations {
        var d: Decorations = .{ .arena = .init(gpa), .style = options.style };
        errdefer d.deinit();
        const a = d.arena.allocator();
        const patterns: ?Patterns = if (options.filter) |f| try .init(a, f) else null;
        const store = repo.refStore();
        var listing = try store.list(gpa, io, "refs/");
        defer listing.deinit();
        const replace = repo.configuration().getBool("core.usereplacerefs", true) catch true;
        for (listing.entries) |entry| {
            if (patterns) |*ps| if (!try ps.admits(gpa, entry.name)) continue;
            const oid = switch (entry.target) {
                .direct => |oid| oid,
                .symbolic => blk: {
                    const resolved = try store.resolve(gpa, io, entry.name) orelse continue;
                    defer gpa.free(resolved.name);
                    break :blk resolved.oid;
                },
            };
            if (std.mem.startsWith(u8, entry.name, "refs/replace/")) {
                if (!replace) continue;
                const original = Oid.parse(repo.objectFormat(), entry.name["refs/replace/".len..]) catch continue;
                _ = repo.objectDatabase().readHeader(io, original) catch |err| switch (err) {
                    error.ObjectNotFound => continue,
                    else => return err,
                };
                try d.add(.grafted, "replaced", original);
                continue;
            }
            try d.addRef(io, repo, kindOf(entry.name), try a.dupe(u8, entry.name), oid);
        }
        const head_admitted = if (patterns) |*ps| try ps.admits(gpa, "HEAD") else true;
        if (if (head_admitted) try store.resolve(gpa, io, "HEAD") else null) |head| {
            defer gpa.free(head.name);
            if (!std.mem.eql(u8, head.name, "HEAD") and std.mem.startsWith(u8, head.name, "refs/")) d.head_branch = try a.dupe(u8, head.name);
            try d.addRef(io, repo, .head, "HEAD", head.oid);
        }
        var grafts = try shallow.read(gpa, io, repo.commonDirectory(), repo.objectFormat());
        defer grafts.deinit(gpa);
        var sorted: std.ArrayList(Oid) = .empty;
        defer sorted.deinit(gpa);
        var it = grafts.keyIterator();
        while (it.next()) |oid| try sorted.append(gpa, oid.*);
        std.mem.sort(Oid, sorted.items, {}, oidLess);
        for (sorted.items) |oid| try d.add(.grafted, "grafted", oid);
        return d;
    }

    /// git's `get_name_decoration`: what decorates `oid`, the last loaded
    /// first, or `null`.
    pub fn of(d: *const Decorations, oid: Oid) ?*const Decoration {
        return d.by_object.get(oid);
    }

    pub fn deinit(d: *Decorations) void {
        d.arena.deinit();
        d.* = undefined;
    }

    fn oidLess(_: void, x: Oid, y: Oid) bool {
        return std.mem.order(u8, x.raw(), y.raw()) == .lt;
    }

    /// git's `ref_namespace` decorations, by the ref's name.
    fn kindOf(name: []const u8) Kind {
        if (std.mem.startsWith(u8, name, "refs/heads/")) return .local;
        if (std.mem.startsWith(u8, name, "refs/tags/")) return .tag;
        if (std.mem.startsWith(u8, name, "refs/remotes/")) return .remote;
        if (std.mem.eql(u8, name, ref_names.stash)) return .stash;
        return .none;
    }

    fn add(d: *Decorations, kind: Kind, name: []const u8, oid: Oid) Allocator.Error!void {
        const a = d.arena.allocator();
        const entry = try d.by_object.getOrPut(a, oid);
        const node = try a.create(Decoration);
        node.* = .{ .kind = kind, .name = name, .next = if (entry.found_existing) entry.value_ptr.* else null };
        entry.value_ptr.* = node;
    }

    /// git's `add_ref_decoration`: the object, and what each tag on the
    /// way points at.
    fn addRef(d: *Decorations, io: Io, repo: *Repository, kind: Kind, name: []const u8, oid: Oid) LoadError!void {
        const header = repo.objectDatabase().readHeader(io, oid) catch |err| switch (err) {
            error.ObjectNotFound => return,
            else => return err,
        };
        try d.add(kind, name, oid);
        var current = oid;
        var current_type = header.type;
        var depth: usize = 0;
        while (current_type == .tag and depth < 64) : (depth += 1) {
            const found = try repo.objectDatabase().read(io, current);
            defer repo.objectDatabase().allocator().free(found.bytes);
            var tag = try object.Tag.parse(repo.allocator(), repo.objectFormat(), found.bytes);
            defer tag.deinit();
            current = tag.target;
            current_type = tag.target_type;
            try d.add(.tag, name, current);
        }
    }

    /// git's `format_decorations` for `oid`, in `colors` where there are.
    pub fn write(d: *const Decorations, a: Allocator, out: *std.ArrayList(u8), oid: Oid, opts: Options, colors: ?*const Colors) Allocator.Error!void {
        const first = d.by_object.get(oid) orelse return;
        // HEAD and the branch it is on, where both are here, are one entry
        // where HEAD stands
        var head_and_current: ?*const Decoration = null;
        var any_head = false;
        var node: ?*const Decoration = first;
        while (node) |n| : (node = n.next) {
            if (n.kind == .head) any_head = true;
        }
        if (any_head) if (d.head_branch) |branch| {
            node = first;
            while (node) |n| : (node = n.next) {
                if (n.kind == .local and std.mem.eql(u8, n.name, branch)) {
                    head_and_current = n;
                    break;
                }
            }
        };
        const commit: []const u8 = if (colors) |c| c.commit.bytes() else "";
        const reset: []const u8 = if (colors != null) color.reset else "";
        var prefix = opts.prefix;
        node = first;
        while (node) |n| : (node = n.next) {
            if (n == head_and_current) continue;
            const own: []const u8 = if (colors) |c| c.of(n.kind) else "";
            if (prefix.len != 0) try out.print(a, "{s}{s}{s}", .{ commit, prefix, reset });
            if (opts.tag.len != 0 and n.kind == .tag) try out.print(a, "{s}{s}{s}", .{ own, opts.tag, reset });
            try out.print(a, "{s}{s}{s}", .{ own, d.named(n.name), reset });
            if (head_and_current) |current| if (n.kind == .head) {
                try out.print(a, "{s}{s}{s}", .{ commit, opts.pointer, reset });
                try out.print(a, "{s}{s}{s}", .{ if (colors) |c| c.of(current.kind) else "", d.named(current.name), reset });
            };
            prefix = opts.separator;
        }
        if (opts.suffix.len != 0) try out.print(a, "{s}{s}{s}", .{ commit, opts.suffix, reset });
    }

    /// A ref's name as the style shows it.
    fn named(d: *const Decorations, name: []const u8) []const u8 {
        return switch (d.style) {
            .short => prettify(name),
            .full => name,
        };
    }

    /// git's `prettify_refname`.
    fn prettify(name: []const u8) []const u8 {
        for ([_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/" }) |p| {
            if (std.mem.startsWith(u8, name, p)) return name[p.len..];
        }
        return name;
    }

    /// git's `decoration_options`, with its defaults.
    pub const Options = struct {
        prefix: []const u8 = " (",
        suffix: []const u8 = ")",
        separator: []const u8 = ", ",
        pointer: []const u8 = " -> ",
        tag: []const u8 = "tag: ",
    };
};

/// git's `show_ident_date`: `sig`'s date as `mode` shows it.
fn showDate(a: Allocator, ctx: Context, out: *std.ArrayList(u8), sig: object.Signature, mode: date.Mode) Error!void {
    try date.show(a, out, sig.when_secs, date.tzInt(sig.offset_minutes), mode, ctx.clock);
}

/// `log.date`: the mode `%ad` and `%cd` show a date in, git's default
/// where it says nothing. A mode git does not know is
/// `error.InvalidDateFormat`, which git dies on.
pub fn configuredDateMode(config: *const config_mod.Config) error{InvalidDateFormat}!date.Mode {
    const value = config.get("log.date") orelse return .{};
    return date.Mode.parse(value) orelse error.InvalidDateFormat;
}

const Parsed = struct {
    oid: Oid,
    commit: object.Commit,
    raw: []const u8,
    /// The message after the blank line that ends the headers.
    message: []const u8,
    /// The commit's own `encoding`, what `%e` writes.
    encoding: ?[]const u8,
};

fn getOneLine(msg: []const u8) usize {
    var i: usize = 0;
    while (i < msg.len) {
        const ch = msg[i];
        if (ch == 0) break;
        i += 1;
        if (ch == '\n') break;
    }
    return i;
}

fn isBlank(line: []const u8) bool {
    for (line) |c| if (!ctype.isSpace(c)) return false;
    return true;
}

fn skipBlankLines(msg: []const u8) []const u8 {
    var rest = msg;
    while (true) {
        const len = getOneLine(rest);
        if (len == 0 or !isBlank(rest[0..len])) break;
        rest = rest[len..];
    }
    return rest;
}

fn uniqueHex(a: Allocator, io: Io, db: *odb_mod.Odb, oid: Oid, len: usize) Error![]const u8 {
    var buf: [hash.max_hex_len]u8 = undefined;
    return a.dupe(u8, try abbrev.unique(io, db, oid, len, &buf));
}

fn person(a: Allocator, ctx: Context, out: *std.ArrayList(u8), sig: object.Signature, part: u8) Error!usize {
    // the capital letters are the mailmap's
    const shown: mailmap_mod.Identity = switch (part) {
        'N', 'E', 'L' => if (ctx.mailmap) |m| m.map(sig.name, sig.email) else .{ .name = sig.name, .email = sig.email },
        else => .{ .name = sig.name, .email = sig.email },
    };
    switch (part) {
        'n', 'N' => try out.appendSlice(a, shown.name),
        'e', 'E' => try out.appendSlice(a, shown.email),
        'l', 'L' => {
            const at = std.mem.findScalar(u8, shown.email, '@') orelse shown.email.len;
            try out.appendSlice(a, shown.email[0..at]);
        },
        // `%ad` in the mode `--date` or `log.date` says, the rest in their own.
        'd' => try showDate(a, ctx, out, sig, ctx.date_mode),
        't' => try showDate(a, ctx, out, sig, .{ .kind = .unix }),
        'D' => try showDate(a, ctx, out, sig, .{ .kind = .rfc2822 }),
        'i' => try showDate(a, ctx, out, sig, .{ .kind = .iso8601 }),
        'I' => try showDate(a, ctx, out, sig, .{ .kind = .iso8601_strict }),
        's' => try showDate(a, ctx, out, sig, .{ .kind = .short }),
        'r' => try showDate(a, ctx, out, sig, .{ .kind = .relative }),
        'h' => try showDate(a, ctx, out, sig, .{ .kind = .human }),
        else => return 0,
    }
    return 2;
}

/// git's `format_sanitized_subject`, what `%f` writes: the letters, digits,
/// dots and underscores of `msg`, every other run one `-`, none at either
/// end, and no run of dots.
pub fn sanitizedSubject(a: Allocator, out: *std.ArrayList(u8), msg: []const u8) Allocator.Error!void {
    const start = out.items.len;
    var space: u2 = 2;
    var i: usize = 0;
    while (i < msg.len) : (i += 1) {
        const c = msg[i];
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_') {
            if (space == 1) try out.append(a, '-');
            space = 0;
            try out.append(a, c);
            if (c == '.') {
                while (i + 1 < msg.len and msg[i + 1] == '.') i += 1;
            }
        } else space |= 1;
    }
    while (out.items.len > start and (out.items[out.items.len - 1] == '.' or out.items[out.items.len - 1] == '-')) _ = out.pop();
}

/// One commit's formatting: the commit, and its signature once checked.
const State = struct {
    a: Allocator,
    io: Io,
    db: *odb_mod.Odb,
    ctx: Context,
    p: Parsed,
    verdict: ?signing.Verdict = null,
    /// git's `auto_color`: whether `%C(auto)` is in force and colours
    /// what follows.
    auto_color: bool = false,
    /// `%w(...)`: where the text it wraps starts, and how: git's
    /// `wrap_start`, `width`, `indent1` and `indent2`.
    wrap_start: usize = 0,
    width: usize = 0,
    indent1: usize = 0,
    indent2: usize = 0,

    /// The colours the placeholders after `%C(auto)` paint with.
    fn autoColors(st: *const State) ?*const Colors {
        return if (st.auto_color) st.ctx.colors else null;
    }
};

/// git's `expand_string_arg`: `%%`, `%n` and `%xNN` in an option's value.
fn expandArg(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        i += 1;
        if (c != '%') {
            try out.append(a, c);
            continue;
        }
        if (i < text.len and text[i] == '%') {
            try out.append(a, '%');
            i += 1;
        } else if (i < text.len and text[i] == 'n') {
            try out.append(a, '\n');
            i += 1;
        } else if (i + 2 < text.len and text[i] == 'x' and percent.hexPair(text[i + 1], text[i + 2]) != null) {
            try out.append(a, percent.hexPair(text[i + 1], text[i + 2]).?);
            i += 3;
        } else try out.append(a, '%');
    }
    return out.items;
}

/// `%(decorate)` and `%(decorate:<options>)`. Options git does not know,
/// or no closing parenthesis, leave it as it stands.
fn decorate(st: *State, out: *std.ArrayList(u8), ph: []const u8) Error!usize {
    var opts: Decorations.Options = .{};
    var at: usize = "(decorate".len;
    if (at < ph.len and ph[at] == ':') {
        at += 1;
        // git's `match_placeholder_arg_value` for each name, until none
        // matches
        outer: while (true) {
            inline for (.{ "prefix", "suffix", "separator", "pointer", "tag" }) |name| {
                if (std.mem.startsWith(u8, ph[at..], name)) {
                    var p = at + name.len;
                    var value: []const u8 = "";
                    var matched = true;
                    if (p < ph.len and ph[p] == '=') {
                        const start = p + 1;
                        p = start;
                        while (p < ph.len and ph[p] != ',' and ph[p] != ')') p += 1;
                        value = ph[start..p];
                    } else if (p >= ph.len or (ph[p] != ',' and ph[p] != ')')) matched = false;
                    if (matched and p < ph.len) {
                        @field(opts, name) = try expandArg(st.a, value);
                        at = if (ph[p] == ',') p + 1 else p;
                        continue :outer;
                    }
                }
            }
            break;
        }
    }
    if (at >= ph.len or ph[at] != ')') return 0;
    if (st.ctx.decorations) |d| try d.write(st.a, out, st.p.oid, opts, st.autoColors());
    return at + 1;
}

/// `%G?`, `%GG`, `%GS`, `%GK`, `%GF`, `%GP` and `%GT`, the signature
/// checked the first time one asks.
fn signature(st: *State, out: *std.ArrayList(u8), ph: []const u8) Error!usize {
    if (ph.len < 2) return 0;
    switch (ph[1]) {
        'G', '?', 'S', 'K', 'F', 'P', 'T' => {},
        else => return 0,
    }
    if (st.verdict == null) {
        const kind = st.db.objectFormat();
        var split = try signing.splitCommit(st.a, kind, st.p.raw);
        if (split) |*s| {
            s.deinit(st.a);
            const signer = st.ctx.signer orelse return error.SignatureNeedsSigner;
            st.verdict = try signing.verifyCommit(st.io, signer, kind, st.p.raw);
        } else st.verdict = .{ .gpa = st.a, .arena = .{} };
    }
    const v = &st.verdict.?;
    const a = st.a;
    switch (ph[1]) {
        'G' => try out.appendSlice(a, v.output),
        '?' => try out.append(a, v.letter()),
        'S' => if (v.signer) |s| try out.appendSlice(a, s),
        'K' => if (v.key) |k| try out.appendSlice(a, k),
        'F' => if (v.fingerprint) |f| try out.appendSlice(a, f),
        'P' => if (v.primary_fingerprint) |f| try out.appendSlice(a, f),
        'T' => try out.appendSlice(a, @tagName(v.trust)),
        else => unreachable,
    }
    return 2;
}

/// `%(trailers)` and `%(trailers:<options>)`: the trailers of the message
/// from its subject on, as git's `format_trailers_from_commit` writes them.
/// Options git does not take, or no closing parenthesis, leave it as it
/// stands.
fn trailers(st: *State, out: *std.ArrayList(u8), ph: []const u8) Error!usize {
    var at: usize = "(trailers".len;
    var options: trailer.Options = .{ .no_divider = true };
    if (at < ph.len and ph[at] == ':') {
        at += 1;
        const parsed = (try trailer.parsePlaceholderOptions(st.a, ph[at..])) orelse return 0;
        options = parsed.options;
        options.no_divider = true;
        at += parsed.len;
    }
    if (at >= ph.len or ph[at] != ')') return 0;
    try trailer.format(st.a, st.ctx.trailers, options, skipBlankLines(cstr(st.p.message)), out);
    return at + 1;
}

/// `%C(auto)`, `%C(...)` and the old `%Cred`, `%Cgreen`, `%Cblue` and
/// `%Creset`, as git's `format_commit_one` and `parse_color` take them:
/// a colour is written where the log has colours, or with `always,`
/// regardless; `auto,` and no prefix are alike. Any of them but `%C(auto)`
/// ends `%C(auto)`; one git does not know is written as it stands, and
/// leaves `%C(auto)` in force.
fn colour(st: *State, out: *std.ArrayList(u8), ph: []const u8) Error!usize {
    const a = st.a;
    const want = st.ctx.colors != null;
    if (std.mem.startsWith(u8, ph[1..], "(auto)")) {
        st.auto_color = want;
        if (want and out.items.len != 0) try out.appendSlice(a, color.reset);
        return "C(auto)".len;
    }
    const consumed: usize = if (ph.len > 1 and ph[1] == '(') blk: {
        const end = std.mem.findScalarPos(u8, ph, 2, ')') orelse return 0;
        var begin: usize = 2;
        if (std.mem.startsWith(u8, ph[begin..end], "auto,")) {
            if (!want) break :blk end + 1;
            begin += "auto,".len;
        } else if (std.mem.startsWith(u8, ph[begin..end], "always,")) {
            begin += "always,".len;
        } else if (!want) break :blk end + 1;
        const parsed = color.parse(ph[begin..end]) catch return error.InvalidColor;
        try out.appendSlice(a, parsed.bytes());
        break :blk end + 1;
    } else blk: {
        const basic = [_]struct { []const u8, []const u8 }{
            .{ "red", color.red.bytes() }, .{ "green", color.green.bytes() }, .{ "blue", color.blue.bytes() }, .{ "reset", color.reset },
        };
        for (basic) |b| if (std.mem.startsWith(u8, ph[1..], b[0])) {
            if (want) try out.appendSlice(a, b[1]);
            break :blk 1 + b[0].len;
        };
        return 0;
    };
    st.auto_color = false;
    return consumed;
}

/// One placeholder, `ph` being what follows the `%`. Returns how many
/// bytes it took, zero for one git does not know.
/// `%w(<width>[,<indent1>[,<indent2>]])`: what came since the last one
/// wrapped as it asked, and what follows wrapped as this one asks. A
/// malformed one, or one past git's 16 KiB of formatting, is no
/// placeholder.
fn wrap(st: *State, out: *std.ArrayList(u8), ph: []const u8) Error!usize {
    if (ph.len < 2 or ph[1] != '(') return 0;
    const end = std.mem.findScalarPos(u8, ph, 2, ')') orelse return 0;
    var values = [3]usize{ 0, 0, 0 };
    if (end > 2) {
        var fields = std.mem.splitScalar(u8, ph[2..end], ',');
        var i: usize = 0;
        while (fields.next()) |field| : (i += 1) {
            if (i == values.len) return 0;
            values[i] = strtoul(field) orelse return 0;
        }
    }
    const limit = 16 * 1024;
    for (values) |v| if (v > limit) return 0;
    try rewrap(st, out, values[0], values[1], values[2]);
    return end + 1;
}

/// C's `strtoul` in base ten over a whole field: blanks, then a sign, then
/// digits; null where anything else is left.
fn strtoul(field: []const u8) ?usize {
    const read = decimal.strtoul(field, 10, @bitSizeOf(usize));
    if (read.end != field.len) return null;
    // cast: `strtoul` gives a value in `usize`'s range, a minus sign
    // taken modulo it
    return @intCast(read.value);
}

/// git's `rewrap_message_tail`.
fn rewrap(st: *State, out: *std.ArrayList(u8), width: usize, indent1: usize, indent2: usize) Allocator.Error!void {
    if (st.width == width and st.indent1 == indent1 and st.indent2 == indent2) return;
    if (st.wrap_start < out.items.len) {
        const tail = try st.a.dupe(u8, out.items[st.wrap_start..]);
        out.shrinkRetainingCapacity(st.wrap_start);
        try mailfmt.appendWrapped(st.a, out, tail, @intCast(st.indent1), @intCast(st.indent2), @intCast(st.width));
    }
    st.wrap_start = out.items.len;
    st.width = width;
    st.indent1 = indent1;
    st.indent2 = indent2;
}

fn one(st: *State, out: *std.ArrayList(u8), ph: []const u8) Error!usize {
    const a = st.a;
    const io = st.io;
    const db = st.db;
    const ctx = st.ctx;
    const p = &st.p;
    if (ph.len == 0) return 0;
    switch (ph[0]) {
        'n' => {
            try out.append(a, '\n');
            return 1;
        },
        'x' => {
            if (ph.len < 3) return 0;
            try out.append(a, percent.hexPair(ph[1], ph[2]) orelse return 0);
            return 3;
        },
        'C' => return colour(st, out, ph),
        'w' => return wrap(st, out, ph),
        '<', '>' => return error.UnsupportedPlaceholder,
        else => {},
    }
    if (std.mem.startsWith(u8, ph, "(decorate")) return decorate(st, out, ph);
    if (std.mem.startsWith(u8, ph, "(trailers")) return trailers(st, out, ph);
    if (std.mem.startsWith(u8, ph, "(count)")) {
        const n = ctx.numbered orelse return error.UnsupportedPlaceholder;
        try out.print(a, "{d:0>[1]}", .{ n.nr, std.fmt.count("{d}", .{n.total}) });
        return "(count)".len;
    }
    if (std.mem.startsWith(u8, ph, "(total)")) {
        const n = ctx.numbered orelse return error.UnsupportedPlaceholder;
        try out.print(a, "{d}", .{n.total});
        return "(total)".len;
    }
    if (std.mem.startsWith(u8, ph, "(describe")) return error.UnsupportedPlaceholder;
    var hexbuf: [hash.max_hex_len]u8 = undefined;
    switch (ph[0]) {
        'H', 'h' => {
            const colors = st.autoColors();
            if (colors) |c| try out.appendSlice(a, c.commit.bytes());
            try out.appendSlice(a, if (ph[0] == 'H') p.oid.hex(&hexbuf) else try uniqueHex(a, io, db, p.oid, ctx.abbrev_len));
            if (colors != null) try out.appendSlice(a, color.reset);
            return 1;
        },
        'T' => {
            try out.appendSlice(a, p.commit.tree.hex(&hexbuf));
            return 1;
        },
        't' => {
            try out.appendSlice(a, try uniqueHex(a, io, db, p.commit.tree, ctx.abbrev_len));
            return 1;
        },
        'P' => {
            for (p.commit.parents, 0..) |parent, i| {
                if (i > 0) try out.append(a, ' ');
                try out.appendSlice(a, parent.hex(&hexbuf));
            }
            return 1;
        },
        'p' => {
            for (p.commit.parents, 0..) |parent, i| {
                if (i > 0) try out.append(a, ' ');
                try out.appendSlice(a, try uniqueHex(a, io, db, parent, ctx.abbrev_len));
            }
            return 1;
        },
        'm' => return 0,
        'd', 'D' => {
            if (ctx.decorations) |d| try d.write(a, out, p.oid, if (ph[0] == 'd') .{} else .{ .prefix = "", .suffix = "" }, st.autoColors());
            return 1;
        },
        'N' => {
            const notes = ctx.notes orelse return 0;
            try out.appendSlice(a, notes);
            return 1;
        },
        'S' => return error.UnsupportedPlaceholder,
        'g' => return error.UnsupportedPlaceholder,
        'G' => return signature(st, out, ph),
        'a' => return if (ph.len >= 2) person(a, ctx, out, p.commit.author, ph[1]) else 0,
        'c' => return if (ph.len >= 2) person(a, ctx, out, p.commit.committer, ph[1]) else 0,
        'e' => {
            if (p.encoding) |e| try out.appendSlice(a, e);
            return 1;
        },
        'B' => {
            try out.appendSlice(a, cstr(p.message));
            return 1;
        },
        's', 'f', 'b' => {
            try messagePart(a, out, cstr(p.message), ph[0]);
            return 1;
        },
        else => return 0,
    }
}

/// `%s`, `%f` or `%b`, as `which` says: the subject paragraph joined onto one
/// line, that subject as a file name, or the body after it.
fn messagePart(a: Allocator, out: *std.ArrayList(u8), msg: []const u8, which: u8) Allocator.Error!void {
    const subject = skipBlankLines(msg);
    // the subject paragraph and where the body starts
    var rest = subject;
    while (true) {
        const len = getOneLine(rest);
        if (len == 0 or isBlank(rest[0..len])) break;
        rest = rest[len..];
    }
    const body = skipBlankLines(rest);
    switch (which) {
        's' => {
            var first = true;
            var r = subject;
            while (true) {
                const len = getOneLine(r);
                if (len == 0 or isBlank(r[0..len])) break;
                var line = r[0..len];
                while (line.len > 0 and ctype.isSpace(line[line.len - 1])) line = line[0 .. line.len - 1];
                if (!first) try out.append(a, ' ');
                try out.appendSlice(a, line);
                first = false;
                r = r[len..];
            }
        },
        'f' => {
            const eol = std.mem.findScalar(u8, subject, '\n') orelse subject.len;
            try sanitizedSubject(a, out, subject[0..eol]);
        },
        'b' => try out.appendSlice(a, body),
        else => unreachable,
    }
}

fn cstr(s: []const u8) []const u8 {
    return if (std.mem.findScalar(u8, s, 0)) |z| s[0..z] else s;
}

/// The object database, commit and format, borrowed for the call.
pub const CommitInputs = struct { db: *odb_mod.Odb, oid: Oid, format: []const u8 };

/// The commit `oid` formatted by `format`, appended to `out`. What `out`
/// already holds is git's buffer before the format, as `git archive`
/// hands it: `%-` removes line ends from it and `%C(auto)` resets after
/// it. A log formats each commit into a buffer of its own.
pub fn formatCommit(a: Allocator, io: Io, inputs: CommitInputs, out: *std.ArrayList(u8), ctx: Context) Self.Error!void {
    const db = inputs.db;
    const oid = inputs.oid;
    const format = inputs.format;
    const found = try db.read(io, oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    const raw = try a.dupe(u8, found.bytes);
    // the placeholders are expanded in UTF-8, the commit converted first
    const utf8 = try reencodeCommit(a, raw, "UTF-8");
    const commit = try object.Commit.parse(a, db.objectFormat(), utf8.bytes);
    var st: State = .{ .a = a, .io = io, .db = db, .ctx = ctx, .p = .{ .oid = oid, .commit = commit, .raw = raw, .message = commit.message, .encoding = utf8.encoding }, .wrap_start = out.items.len };
    defer if (st.verdict) |*v| v.deinit();
    var at: usize = 0;
    while (at < format.len) {
        const pct = std.mem.findScalarPos(u8, format, at, '%') orelse {
            try out.appendSlice(a, format[at..]);
            break;
        };
        try out.appendSlice(a, format[at..pct]);
        var ph = format[pct + 1 ..];
        if (ph.len > 0 and ph[0] == '%') {
            try out.append(a, '%');
            at = pct + 2;
            continue;
        }
        // the modifiers: %+x, %-x, % x
        var magic: u8 = 0;
        if (ph.len > 0 and (ph[0] == '+' or ph[0] == '-' or ph[0] == ' ')) {
            magic = ph[0];
            ph = ph[1..];
            if (ph.len > 0 and ph[0] == 'w') {
                try out.append(a, '%');
                at = pct + 1;
                continue;
            }
        }
        const orig_len = out.items.len;
        const consumed = try one(&st, out, ph);
        if (consumed == 0) {
            try out.append(a, '%');
            at = pct + 1;
            continue;
        }
        if (magic != 0) {
            if (orig_len == out.items.len and magic == '-') {
                while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
            } else if (orig_len != out.items.len) {
                if (magic == '+') try out.insert(a, orig_len, '\n') else if (magic == ' ') try out.insert(a, orig_len, ' ');
            }
        }
        at = pct + 1 + @as(usize, @intFromBool(magic != 0)) + consumed;
    }
    try rewrap(&st, out, 0, 0, 0);
    // then into the output's encoding: git converts the whole buffer it
    // was handed, what was in it before included
    const converted = try toOutput(a, out.items, outputEncoding(ctx.output_encoding, utf8.encoding));
    if (converted.ptr != out.items.ptr) {
        out.clearRetainingCapacity();
        try out.appendSlice(a, converted);
    }
}

/// The encoding git's `format_commit_message` writes in: `output` unless
/// it is UTF-8, else for an unset one the commit's own `encoding` unless
/// that is UTF-8. `null` is UTF-8, no conversion.
pub fn outputEncoding(output: ?[]const u8, commit_encoding: ?[]const u8) ?[]const u8 {
    const e = output orelse commit_encoding orelse return null;
    return if (encoding.same("UTF-8", e)) null else e;
}

/// `text`, formatted in UTF-8, in `output` (`outputEncoding`'s): as it
/// is where `output` is `null` or the conversion stops, as git keeps it.
pub fn toOutput(a: Allocator, text: []const u8, output: ?[]const u8) encoding.ReencodeError![]const u8 {
    const e = output orelse return text;
    return try encoding.reencode(a, text, e, "UTF-8") orelse text;
}

test "placeholders come out as git's do" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try showDate(arena.allocator(), .{}, &out, .{ .name = "", .email = "", .when_secs = 1700000000, .offset_minutes = 60 }, .{});
    try std.testing.expectEqualStrings("Tue Nov 14 23:13:20 2023 +0100", out.items);
    out.clearRetainingCapacity();
    try showDate(arena.allocator(), .{}, &out, .{ .name = "", .email = "", .when_secs = 1700000000, .offset_minutes = 0 }, .{ .kind = .iso8601_strict });
    try std.testing.expectEqualStrings("2023-11-14T22:13:20Z", out.items);
}
