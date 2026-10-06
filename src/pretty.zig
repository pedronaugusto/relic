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
//! its `trailers` settings say. What needs more — `%(describe)`, relative
//! and human dates, wrapping, padding and colour — is refused as
//! `error.UnsupportedPlaceholder`.

const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const abbrev = @import("odb/abbrev.zig");
const mailfmt = @import("patch/mail/format.zig");
const repo_mod = @import("repo.zig");
const refs_mod = @import("refs.zig");
const shallow = @import("revwalk/shallow.zig");
const signing = @import("commit/signing.zig");
const trailer = @import("commit/trailer.zig");
const mailmap_mod = @import("revwalk/mailmap.zig");

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
} || signing.Error || odb_mod.Error || object.ParseError || Allocator.Error;

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
};

/// The refs that point at each object, as git loads them for a format:
/// every ref, then `HEAD`, then the shallow commits as `grafted`; a tag
/// names what it points at too, and `refs/replace/<oid>` marks `<oid>`
/// as `replaced`. Each object's names come newest first, as git lists
/// them.
pub const Decorations = struct {
    arena: std.heap.ArenaAllocator,
    by_object: Oid.Map(*const Decoration) = .empty,
    /// The ref `HEAD` points at, written `HEAD -> <branch>` where both
    /// decorate one commit.
    head_branch: ?[]const u8 = null,

    /// git's `decoration_type`.
    pub const Kind = enum { none, local, remote, tag, stash, head, grafted };

    pub const Decoration = struct {
        kind: Kind,
        /// The whole ref name.
        name: []const u8,
        next: ?*const Decoration,
    };

    pub const LoadError = refs_mod.ReadError || odb_mod.Error || object.ParseError || shallow.ReadError || Allocator.Error;

    /// git's `load_ref_decorations` with no filter.
    pub fn load(gpa: Allocator, io: Io, repo: *Repository) LoadError!Decorations {
        var d: Decorations = .{ .arena = .init(gpa) };
        errdefer d.deinit();
        const a = d.arena.allocator();
        const store = repo.refStore();
        var listing = try store.list(gpa, io, "refs/");
        defer listing.deinit();
        const replace = repo.configuration().getBool("core.usereplacerefs", true) catch true;
        for (listing.entries) |entry| {
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
                _ = repo.odb.readHeader(io, original) catch |err| switch (err) {
                    error.ObjectNotFound => continue,
                    else => return err,
                };
                try d.add(.grafted, "replaced", original);
                continue;
            }
            try d.addRef(io, repo, kindOf(entry.name), try a.dupe(u8, entry.name), oid);
        }
        if (try store.resolve(gpa, io, "HEAD")) |head| {
            defer gpa.free(head.name);
            if (!std.mem.eql(u8, head.name, "HEAD") and std.mem.startsWith(u8, head.name, "refs/")) d.head_branch = try a.dupe(u8, head.name);
            try d.addRef(io, repo, .head, "HEAD", head.oid);
        }
        var grafts = try shallow.read(gpa, io, repo.common_dir, repo.objectFormat());
        defer grafts.deinit(gpa);
        var sorted: std.ArrayList(Oid) = .empty;
        defer sorted.deinit(gpa);
        var it = grafts.keyIterator();
        while (it.next()) |oid| try sorted.append(gpa, oid.*);
        std.mem.sort(Oid, sorted.items, {}, oidLess);
        for (sorted.items) |oid| try d.add(.grafted, "grafted", oid);
        return d;
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
        if (std.mem.eql(u8, name, "refs/stash")) return .stash;
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
        const header = repo.odb.readHeader(io, oid) catch |err| switch (err) {
            error.ObjectNotFound => return,
            else => return err,
        };
        try d.add(kind, name, oid);
        var current = oid;
        var current_type = header.type;
        var depth: usize = 0;
        while (current_type == .tag and depth < 64) : (depth += 1) {
            const found = try repo.odb.read(io, current);
            defer repo.odb.allocator().free(found.bytes);
            var tag = try object.Tag.parse(repo.gpa, repo.objectFormat(), found.bytes);
            defer tag.deinit();
            current = tag.target;
            current_type = tag.target_type;
            try d.add(.tag, name, current);
        }
    }

    /// git's `format_decorations` for `oid`.
    fn write(d: *const Decorations, a: Allocator, out: *std.ArrayList(u8), oid: Oid, opts: Options) Allocator.Error!void {
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
        var prefix = opts.prefix;
        node = first;
        while (node) |n| : (node = n.next) {
            if (n == head_and_current) continue;
            try out.appendSlice(a, prefix);
            if (n.kind == .tag) try out.appendSlice(a, opts.tag);
            try out.appendSlice(a, prettify(n.name));
            if (head_and_current != null and n.kind == .head) {
                try out.appendSlice(a, opts.pointer);
                try out.appendSlice(a, prettify(head_and_current.?.name));
            }
            prefix = opts.separator;
        }
        try out.appendSlice(a, opts.suffix);
    }

    /// git's `prettify_refname`.
    fn prettify(name: []const u8) []const u8 {
        for ([_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/" }) |p| {
            if (std.mem.startsWith(u8, name, p)) return name[p.len..];
        }
        return name;
    }

    /// git's `decoration_options`, with its defaults.
    const Options = struct {
        prefix: []const u8 = " (",
        suffix: []const u8 = ")",
        separator: []const u8 = ", ",
        pointer: []const u8 = " -> ",
        tag: []const u8 = "tag: ",
    };
};

const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

const DateMode = enum { normal, rfc2822, iso, iso_strict, short, unix };

fn writeDate(a: Allocator, out: *std.ArrayList(u8), sig: object.Signature, mode: DateMode) Allocator.Error!void {
    if (mode == .unix) {
        try out.print(a, "{d}", .{sig.when_secs});
        return;
    }
    const tz = mailfmt.tzInt(sig.offset_minutes);
    const c = mailfmt.civil(sig.when_secs + @as(i64, sig.offset_minutes) * 60);
    const sign: u8 = if (tz < 0) '-' else '+';
    const abs_tz = @abs(tz);
    switch (mode) {
        .normal => try out.print(a, "{s} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {d} {c}{d:0>4}", .{ weekday_names[c.weekday], month_names[c.month - 1], c.day, c.hour, c.minute, c.second, c.year, sign, abs_tz }),
        .rfc2822 => try out.print(a, "{s}, {d} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {c}{d:0>4}", .{ weekday_names[c.weekday], c.day, month_names[c.month - 1], c.year, c.hour, c.minute, c.second, sign, abs_tz }),
        .iso => try out.print(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {c}{d:0>4}", .{ @as(u64, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second, sign, abs_tz }),
        .iso_strict => {
            try out.print(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second });
            if (tz == 0) try out.append(a, 'Z') else try out.print(a, "{c}{d:0>2}:{d:0>2}", .{ sign, abs_tz / 100, abs_tz % 100 });
        },
        .short => try out.print(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(c.year)), c.month, c.day }),
        .unix => unreachable,
    }
}

const Parsed = struct {
    oid: Oid,
    commit: object.Commit,
    raw: []const u8,
    /// The message after the blank line that ends the headers.
    message: []const u8,
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

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

fn isBlank(line: []const u8) bool {
    for (line) |c| if (!isSpace(c)) return false;
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
            const at = std.mem.indexOfScalar(u8, shown.email, '@') orelse shown.email.len;
            try out.appendSlice(a, shown.email[0..at]);
        },
        't' => try writeDate(a, out, sig, .unix),
        'd' => try writeDate(a, out, sig, .normal),
        'D' => try writeDate(a, out, sig, .rfc2822),
        'i' => try writeDate(a, out, sig, .iso),
        'I' => try writeDate(a, out, sig, .iso_strict),
        's' => try writeDate(a, out, sig, .short),
        'r', 'h' => return error.UnsupportedPlaceholder,
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
        } else if (i + 2 < text.len and text[i] == 'x') {
            const hi = std.fmt.charToDigit(text[i + 1], 16) catch {
                try out.append(a, '%');
                continue;
            };
            const lo = std.fmt.charToDigit(text[i + 2], 16) catch {
                try out.append(a, '%');
                continue;
            };
            try out.append(a, hi << 4 | lo);
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
    if (st.ctx.decorations) |d| try d.write(st.a, out, st.p.oid, opts);
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
            st.verdict = try signing.verifyCommit(signer, st.io, kind, st.p.raw);
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

/// One placeholder, `ph` being what follows the `%`. Returns how many
/// bytes it took, zero for one git does not know.
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
            if (ph.len >= 3) {
                const hi = std.fmt.charToDigit(ph[1], 16) catch return 0;
                const lo = std.fmt.charToDigit(ph[2], 16) catch return 0;
                try out.append(a, hi << 4 | lo);
                return 3;
            }
            return 0;
        },
        'C', 'w', '<', '>' => return error.UnsupportedPlaceholder,
        else => {},
    }
    if (std.mem.startsWith(u8, ph, "(decorate")) return decorate(st, out, ph);
    if (std.mem.startsWith(u8, ph, "(trailers")) return trailers(st, out, ph);
    if (std.mem.startsWith(u8, ph, "(describe") or std.mem.startsWith(u8, ph, "(count)") or
        std.mem.startsWith(u8, ph, "(total)")) return error.UnsupportedPlaceholder;
    var hexbuf: [hash.max_hex_len]u8 = undefined;
    switch (ph[0]) {
        'H' => {
            try out.appendSlice(a, p.oid.hex(&hexbuf));
            return 1;
        },
        'h' => {
            try out.appendSlice(a, try uniqueHex(a, io, db, p.oid, ctx.abbrev_len));
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
            if (ctx.decorations) |d| try d.write(a, out, p.oid, if (ph[0] == 'd') .{} else .{ .prefix = "", .suffix = "" });
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
            if (p.commit.encoding) |e| try out.appendSlice(a, e);
            return 1;
        },
        'B' => {
            try out.appendSlice(a, cstr(p.message));
            return 1;
        },
        's', 'f', 'b' => {
            const msg = cstr(p.message);
            const subject = skipBlankLines(msg);
            // the subject paragraph and where the body starts
            var rest = subject;
            while (true) {
                const len = getOneLine(rest);
                if (len == 0 or isBlank(rest[0..len])) break;
                rest = rest[len..];
            }
            const body = skipBlankLines(rest);
            switch (ph[0]) {
                's' => {
                    var first = true;
                    var r = subject;
                    while (true) {
                        const len = getOneLine(r);
                        if (len == 0 or isBlank(r[0..len])) break;
                        var line = r[0..len];
                        while (line.len > 0 and isSpace(line[line.len - 1])) line = line[0 .. line.len - 1];
                        if (!first) try out.append(a, ' ');
                        try out.appendSlice(a, line);
                        first = false;
                        r = r[len..];
                    }
                },
                'f' => {
                    const eol = std.mem.indexOfScalar(u8, subject, '\n') orelse subject.len;
                    try sanitizedSubject(a, out, subject[0..eol]);
                },
                'b' => try out.appendSlice(a, body),
                else => unreachable,
            }
            return 1;
        },
        else => return 0,
    }
}

fn cstr(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, 0)) |z| s[0..z] else s;
}

/// The commit `oid` formatted by `format`, appended to `out`.
pub fn formatCommit(a: Allocator, io: Io, db: *odb_mod.Odb, oid: Oid, format: []const u8, ctx: Context, out: *std.ArrayList(u8)) Self.Error!void {
    const found = try db.read(io, oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    const raw = try a.dupe(u8, found.bytes);
    const commit = try object.Commit.parse(a, db.objectFormat(), raw);
    var st: State = .{ .a = a, .io = io, .db = db, .ctx = ctx, .p = .{ .oid = oid, .commit = commit, .raw = raw, .message = commit.message } };
    defer if (st.verdict) |*v| v.deinit();
    var at: usize = 0;
    while (at < format.len) {
        const pct = std.mem.indexOfScalarPos(u8, format, at, '%') orelse {
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
}

test "placeholders come out as git's do" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try writeDate(arena.allocator(), &out, .{ .name = "", .email = "", .when_secs = 1700000000, .offset_minutes = 60 }, .normal);
    try std.testing.expectEqualStrings("Tue Nov 14 23:13:20 2023 +0100", out.items);
    out.clearRetainingCapacity();
    try writeDate(arena.allocator(), &out, .{ .name = "", .email = "", .when_secs = 1700000000, .offset_minutes = 0 }, .iso_strict);
    try std.testing.expectEqualStrings("2023-11-14T22:13:20Z", out.items);
}
