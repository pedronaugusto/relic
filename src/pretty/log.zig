//! A log's entry for one commit, as `git log`, `git show` and `git
//! whatchanged` write it (git's `show_log` and `pretty_print_commit`):
//! the `commit` line, cut short under `--abbrev-commit` or
//! `log.abbrevCommit`, with its decorations; the signature git's
//! `--show-signature` or `log.showSignature` checks, and a merge's
//! mergetags; then the commit in one of git's built-in formats, `raw`,
//! `medium`, `short`, `full`, `fuller` or `oneline`, and its notes.
//!
//! `Choice` is the format a log takes, as git's `get_commit_format`
//! reads `--pretty`, `--format` and `format.pretty`: a built-in format by
//! name or any prefix of one, `reference`, a `pretty.<name>` alias, or
//! placeholders for `pretty.formatCommit`. `email` and `mboxrd`, the
//! formats of a mail, are `patch.format`'s.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const abbrev = @import("../odb/abbrev.zig");
const signing = @import("../object/signing.zig");
const config_mod = @import("../config/config.zig");
const color = @import("../config/color.zig");
const ctype = @import("../text.zig").ctype;
const date = @import("../text.zig").date;
const unicode_width = @import("../text.zig").unicode_width;
const mailmap_mod = @import("../rev_walk/mailmap.zig");
const pretty = @import("pretty.zig");

const Oid = hash.Oid;
const Context = pretty.Context;

/// Errors from writing an entry: formatting's.
pub const Error = pretty.Error;

/// git's built-in formats of a log, the mail ones aside.
pub const Builtin = enum { raw, medium, short, full, fuller, oneline };

/// What each entry is written in.
pub const Format = union(enum) {
    builtin: Builtin,
    /// Placeholders, as `pretty.formatCommit` expands them.
    user: []const u8,
};

/// The format a log takes and what comes with it.
pub const Choice = struct {
    format: Format = .{ .builtin = .medium },
    /// Whether each entry ends in a newline, as `oneline`, `reference`
    /// and `tformat:` end, rather than the entries being separated by
    /// one: git's `use_terminator`.
    terminator: bool = false,
    /// The columns a tab in the message is expanded to, `0` for none:
    /// `medium`, `full` and `fuller` take 8, as git's
    /// `expand_tabs_in_log_default` (`--expand-tabs` and
    /// `--no-expand-tabs` say otherwise).
    expand_tabs: usize = 0,
    /// The date mode the format takes where `--date` gives none:
    /// `reference`'s `short`.
    date_mode: ?date.Mode = null,
};

/// Errors from reading a format.
pub const ParseError = error{
    /// Neither placeholders nor the name, or the start of the name, of a
    /// format git knows or the configuration names: git's "invalid
    /// --pretty format".
    UnknownFormat,
    /// A `pretty.<name>` alias that comes back to itself.
    AliasLoop,
    /// `email` or `mboxrd`: a mail, which `patch.format` writes.
    MailFormat,
    /// A `pretty.<name>` with no value, which git dies on.
    MissingValue,
} || Allocator.Error;

const Named = struct {
    name: []const u8,
    format: union(enum) { builtin: Builtin, mail, user: []const u8, alias: []const u8 },
    terminator: bool = false,
    expand_tabs: usize = 0,
    date_mode: ?date.Mode = null,
};

/// git's `builtin_formats`, in its order.
const builtins = [_]Named{
    .{ .name = "raw", .format = .{ .builtin = .raw } },
    .{ .name = "medium", .format = .{ .builtin = .medium }, .expand_tabs = 8 },
    .{ .name = "short", .format = .{ .builtin = .short } },
    .{ .name = "email", .format = .mail },
    .{ .name = "mboxrd", .format = .mail },
    .{ .name = "fuller", .format = .{ .builtin = .fuller }, .expand_tabs = 8 },
    .{ .name = "full", .format = .{ .builtin = .full }, .expand_tabs = 8 },
    .{ .name = "oneline", .format = .{ .builtin = .oneline }, .terminator = true },
    .{ .name = "reference", .format = .{ .user = "%C(auto)%h (%s, %ad)" }, .terminator = true, .date_mode = .{ .kind = .short } },
};

/// `--pretty=<arg>` or `--format=<arg>`, as git's `get_commit_format`
/// reads it: `format:<placeholders>`, separated; `tformat:` or anything
/// with a `%`, terminated; else the format whose name `arg` begins, the
/// shortest such name taken, `pretty.<name>` aliases in `config` among
/// them. `null`, a bare `--pretty`, is `medium`. What it returns is
/// `arena`'s or `arg`'s.
pub fn parse(arena: Allocator, config: ?*const config_mod.Config, arg: ?[]const u8) ParseError!Choice {
    const text = arg orelse return choiceOf(builtins[1]);
    if (std.mem.startsWith(u8, text, "format:")) return .{ .format = .{ .user = text["format:".len..] } };
    if (std.mem.startsWith(u8, text, "tformat:")) return .{ .format = .{ .user = text["tformat:".len..] }, .terminator = true };
    if (text.len == 0 or std.mem.findScalar(u8, text, '%') != null) return .{ .format = .{ .user = text }, .terminator = true };
    const formats = try known(arena, config);
    var sought = text;
    for (0..formats.len + 1) |_| {
        const found = findFormat(formats, sought) orelse return error.UnknownFormat;
        switch (found.format) {
            .alias => |target| sought = target,
            .mail => return error.MailFormat,
            else => return choiceOf(found),
        }
    }
    return error.AliasLoop;
}

/// The format `git log` and `git show` take when the caller names none:
/// `format.pretty`, read as `parse` reads `--pretty`, else `medium`.
pub fn configured(arena: Allocator, config: *const config_mod.Config) ParseError!Choice {
    const entry = config.find("format.pretty") orelse return choiceOf(builtins[1]);
    return parse(arena, config, entry.value orelse return error.MissingValue);
}

/// `log.abbrevCommit`: whether a log cuts the `commit` line's name short,
/// as `--abbrev-commit` does.
pub fn configuredAbbrevCommit(config: *const config_mod.Config) config_mod.ValueError!bool {
    return config.getBool("log.abbrevcommit", false);
}

/// `log.showSignature`: whether a log checks each commit's signature, as
/// `--show-signature` does.
pub fn configuredShowSignature(config: *const config_mod.Config) config_mod.ValueError!bool {
    return config.getBool("log.showsignature", false);
}

fn choiceOf(n: Named) Choice {
    return .{
        .format = switch (n.format) {
            .builtin => |b| .{ .builtin = b },
            .user => |u| .{ .user = u },
            .mail, .alias => unreachable,
        },
        .terminator = n.terminator,
        .expand_tabs = n.expand_tabs,
        .date_mode = n.date_mode,
    };
}

/// git's `setup_commit_formats`: the built-in formats, then each
/// `pretty.<name>` the configuration sets, the last value of one name
/// kept, none taking a built-in's name.
fn known(arena: Allocator, config: ?*const config_mod.Config) ParseError![]const Named {
    var list: std.ArrayList(Named) = .empty;
    try list.appendSlice(arena, &builtins);
    const c = config orelse return list.items;
    for (c.entries.items) |entry| {
        if (!std.mem.eql(u8, entry.section, "pretty")) continue;
        // git takes what follows `pretty.`, a subsection's dot and all
        const name = if (entry.has_subsection) try std.mem.concat(arena, u8, &.{ entry.subsection, ".", entry.name }) else entry.name;
        if (isBuiltin(name)) continue;
        const value = entry.value orelse return error.MissingValue;
        const n: Named = if (std.mem.startsWith(u8, value, "format:"))
            .{ .name = name, .format = .{ .user = value["format:".len..] } }
        else if (std.mem.startsWith(u8, value, "tformat:"))
            .{ .name = name, .format = .{ .user = value["tformat:".len..] }, .terminator = true }
        else if (std.mem.findScalar(u8, value, '%') != null)
            .{ .name = name, .format = .{ .user = value }, .terminator = true }
        else
            .{ .name = name, .format = .{ .alias = value } };
        for (list.items[builtins.len..]) |*existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                existing.* = n;
                break;
            }
        } else try list.append(arena, n);
    }
    return list.items;
}

fn isBuiltin(name: []const u8) bool {
    for (builtins) |b| if (std.mem.eql(u8, b.name, name)) return true;
    return false;
}

/// git's `find_commit_format_recursive`, one step: the shortest name that
/// begins with `sought`, ignoring case; the first of equal ones.
fn findFormat(formats: []const Named, sought: []const u8) ?Named {
    var found: ?Named = null;
    for (formats) |f| {
        if (!std.ascii.startsWithIgnoreCase(f.name, sought)) continue;
        if (found == null or found.?.name.len > f.name.len) found = f;
    }
    return found;
}

/// The commit an entry is written for, and where its objects are.
pub const EntryInputs = struct {
    db: *odb_mod.Odb,
    oid: Oid,
};

/// How an entry is written.
pub const EntryOptions = struct {
    /// What the formatting reads besides the commit: the mailmap,
    /// decorations, notes, signer, colours, date mode and encoding.
    context: Context = .{},
    format: Builtin = .medium,
    /// `--abbrev-commit`, `log.abbrevCommit`: the `commit` line's name
    /// and `from`'s cut to `Context.abbrev_len` digits, or as many more as
    /// make them unique; else whole.
    abbrev_commit: bool = false,
    /// The parent a diff of a merge is shown against, as `-m` shows each:
    /// ` (from <parent>)` on the `commit` line.
    from: ?Oid = null,
    /// `--show-signature`, `log.showSignature`: gpg's lines for the
    /// commit's signature after the `commit` line, and for each mergetag
    /// of a merge, by `Context.signer`.
    show_signature: bool = false,
    /// The columns a tab in the message is expanded to: `Choice`'s.
    expand_tabs: usize = 0,
    /// Whether an entry came before this one, which a format with no
    /// terminator is separated from by a newline (`Choice.terminator`).
    after_another: bool = false,
    terminator: bool = false,
};

/// Append the entry for `inputs.oid` to `out`, as git's `show_log`
/// writes it in a built-in format: the `commit` line in
/// `Context.colors`' commit colour, its decorations from
/// `Context.decorations`, the signatures `show_signature` asks for, the
/// commit in `options.format` — the people as `Context.mailmap` maps them,
/// their dates in `Context.date_mode`, the message in
/// `Context.output_encoding` — and `Context.notes`, which are the notes as
/// git writes them for such a format (`commit.notes`' `raw = false`).
pub fn writeEntry(a: Allocator, io: Io, inputs: EntryInputs, out: *std.ArrayList(u8), options: EntryOptions) Self.Error!void {
    const ctx = options.context;
    const db = inputs.db;
    const found = try db.read(io, inputs.oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    const raw = try a.dupe(u8, found.bytes);
    const commit = try object.Commit.parse(a, db.objectFormat(), raw);
    if (options.after_another and !options.terminator) try out.append(a, '\n');

    const reset: []const u8 = if (ctx.colors != null) color.reset else "";
    const fmt = options.format;
    if (ctx.colors) |c| try out.appendSlice(a, c.commit.bytes());
    if (fmt != .oneline) try out.appendSlice(a, "commit ");
    try out.appendSlice(a, try commitName(a, io, db, inputs.oid, ctx, options.abbrev_commit));
    if (options.from) |parent| try out.print(a, " (from {s})", .{try commitName(a, io, db, parent, ctx, options.abbrev_commit)});
    try out.appendSlice(a, reset);
    if (ctx.decorations) |d| try d.write(a, out, inputs.oid, .{ .colors = ctx.colors });
    try out.append(a, if (fmt == .oneline) ' ' else '\n');

    if (options.show_signature) {
        try showSignature(a, io, db, out, raw, ctx);
        try showMergetags(a, io, db, out, commit, ctx);
    }

    var body: std.ArrayList(u8) = .empty;
    try prettyPrint(a, io, db, &body, raw, commit, ctx, options);
    if (ctx.notes) |notes| try body.appendSlice(a, notes);
    try out.appendSlice(a, body.items);
    if (options.terminator) try out.append(a, '\n');
}

fn commitName(a: Allocator, io: Io, db: *odb_mod.Odb, oid: Oid, ctx: Context, short: bool) Self.Error![]const u8 {
    var buf: [hash.max_hex_len]u8 = undefined;
    if (!short) return a.dupe(u8, oid.hex(&buf));
    return a.dupe(u8, try abbrev.unique(io, db, oid, ctx.abbrev_len, &buf));
}

/// git's `show_sig_lines`: each line in the frag colour for a good
/// signature, the whitespace one for any other.
fn sigLines(a: Allocator, out: *std.ArrayList(u8), good: bool, text: []const u8, ctx: Context) Allocator.Error!void {
    const set: []const u8 = if (ctx.colors) |c| (if (good) c.frag.bytes() else c.whitespace.bytes()) else "";
    const reset: []const u8 = if (ctx.colors != null) color.reset else "";
    var rest = text;
    while (rest.len > 0) {
        const eol = std.mem.findScalar(u8, rest, '\n');
        const line = rest[0 .. eol orelse rest.len];
        try out.print(a, "{s}{s}{s}{s}", .{ set, line, reset, if (eol != null) "\n" else "" });
        rest = if (eol) |e| rest[e + 1 ..] else rest[rest.len..];
    }
}

/// git's `check_signature` passing: a good signature from a key trusted
/// as far as `gpg.minTrustLevel` asks.
fn passes(v: *const signing.Verdict, signer: *const signing.Signer) bool {
    return v.accepted and v.result == .good and @backingInt(v.trust) >= @backingInt(signer.min_trust);
}

/// git's `show_signature`: nothing for a commit with no signature.
fn showSignature(a: Allocator, io: Io, db: *odb_mod.Odb, out: *std.ArrayList(u8), raw: []const u8, ctx: Context) Self.Error!void {
    const kind = db.objectFormat();
    var split = (try signing.splitCommit(a, kind, raw)) orelse return;
    split.deinit(a);
    const signer = ctx.signer orelse return error.SignatureNeedsSigner;
    var verdict = try signing.verifyCommit(io, signer, kind, raw);
    defer verdict.deinit();
    const ok = passes(&verdict, signer);
    try sigLines(a, out, ok, if (!ok and verdict.output.len == 0) "No signature\n" else verdict.output, ctx);
}

/// git's `show_mergetag`: for each tag a merge records, what it tags
/// among the parents and its signature's lines.
fn showMergetags(a: Allocator, io: Io, db: *odb_mod.Odb, out: *std.ArrayList(u8), commit: object.Commit, ctx: Context) Self.Error!void {
    const kind = db.objectFormat();
    for (commit.extra) |h| {
        if (!std.mem.eql(u8, h.name, "mergetag")) continue;
        var message: std.ArrayList(u8) = .empty;
        if (object.Tag.parse(a, kind, h.value)) |tag| {
            var hex: [hash.max_hex_len]u8 = undefined;
            const nth = for (commit.parents, 0..) |p, i| {
                if (p.eql(tag.target)) break i;
            } else null;
            if (commit.parents.len == 2 and commit.parents[1].eql(tag.target)) {
                try message.print(a, "merged tag '{s}'\n", .{tag.name});
            } else if (nth) |i| {
                try message.print(a, "parent #{d}, tagged '{s}'\n", .{ i + 1, tag.name });
            } else try message.print(a, "tag {s} names a non-parent {s}\n", .{ tag.name, tag.target.hex(&hex) });
        } else |_| try message.appendSlice(a, "malformed mergetag\n");
        var ok = false;
        var split = try signing.splitTag(a, h.value);
        if (split) |*s| {
            s.deinit(a);
            const signer = ctx.signer orelse return error.SignatureNeedsSigner;
            var verdict = try signing.verifyTag(io, signer, kind, h.value);
            defer verdict.deinit();
            ok = passes(&verdict, signer);
            try message.appendSlice(a, if (verdict.output.len != 0) verdict.output else "No signature\n");
        }
        try sigLines(a, out, ok, message.items, ctx);
    }
}

/// git's `pretty_print_commit` for a built-in format: the headers the
/// format shows, a blank line, the message indented four columns (none for
/// `oneline`, which writes the subject alone), trailing space gone, and a
/// newline but after `oneline`.
fn prettyPrint(a: Allocator, io: Io, db: *odb_mod.Odb, out: *std.ArrayList(u8), raw: []const u8, commit: object.Commit, ctx: Context, options: EntryOptions) Self.Error!void {
    const fmt = options.format;
    const shown = try pretty.reencodeCommit(a, raw, ctx.output_encoding orelse "UTF-8");
    var msg = shown.bytes;
    try header(a, io, db, out, &msg, commit, ctx, fmt);
    if (fmt != .oneline) try out.append(a, '\n');
    msg = skipBlankLines(msg);
    if (fmt == .oneline) {
        msg = try subject(a, out, msg);
        try out.append(a, '\n');
    } else try remainder(a, out, msg, fmt, options.expand_tabs);
    while (out.items.len > 0 and ctype.isSpace(out.items[out.items.len - 1])) _ = out.pop();
    if (fmt != .oneline) try out.append(a, '\n');
}

/// git's `pp_header`: `raw` copies every header line; the others write
/// `Merge:` for a merge and the people their format shows.
fn header(a: Allocator, io: Io, db: *odb_mod.Odb, out: *std.ArrayList(u8), msg: *[]const u8, commit: object.Commit, ctx: Context, fmt: Builtin) Self.Error!void {
    var parents_shown = false;
    while (true) {
        const len = getOneLine(msg.*);
        if (len == 0) return;
        const line = msg.*[0..len];
        msg.* = msg.*[len..];
        if (len == 1) return;
        if (fmt == .raw) {
            try out.appendSlice(a, line);
            continue;
        }
        if (std.mem.startsWith(u8, line, "parent ")) continue;
        if (!parents_shown) {
            parents_shown = true;
            if (fmt != .oneline and commit.parents.len > 1) {
                try out.appendSlice(a, "Merge:");
                for (commit.parents) |p| {
                    var buf: [hash.max_hex_len]u8 = undefined;
                    try out.print(a, " {s}", .{if (ctx.abbrev_len != 0) try abbrev.unique(io, db, p, ctx.abbrev_len, &buf) else p.hex(&buf)});
                }
                try out.append(a, '\n');
            }
        }
        if (std.mem.startsWith(u8, line, "author ")) try userInfo(a, out, "Author", line["author ".len..], ctx, fmt);
        if (std.mem.startsWith(u8, line, "committer ") and (fmt == .full or fmt == .fuller)) try userInfo(a, out, "Commit", line["committer ".len..], ctx, fmt);
    }
}

/// git's `pp_user_info` outside a mail: `<what>: <name> <<email>>`, and
/// the date the format shows.
fn userInfo(a: Allocator, out: *std.ArrayList(u8), what: []const u8, line: []const u8, ctx: Context, fmt: Builtin) Self.Error!void {
    if (fmt == .oneline) return;
    const ident = object.Signature.parse(std.mem.trimEnd(u8, line, "\n")) catch return;
    const person: mailmap_mod.Identity = if (ctx.mailmap) |m| m.map(ident.name, ident.email) else .{ .name = ident.name, .email = ident.email };
    try out.print(a, "{s}: {s}{s} <{s}>\n", .{ what, if (fmt == .fuller) "    " else "", person.name, person.email });
    switch (fmt) {
        .medium => try out.appendSlice(a, "Date:   "),
        .fuller => try out.print(a, "{s}Date: ", .{what}),
        else => return,
    }
    try date.show(a, out, ident.when_secs, date.tzInt(ident.offset_minutes), ctx.date_mode, ctx.clock);
    try out.append(a, '\n');
}

/// git's `format_subject` with a space between lines: the first
/// paragraph on one line. The rest of `msg`.
fn subject(a: Allocator, out: *std.ArrayList(u8), msg: []const u8) Allocator.Error![]const u8 {
    var rest = msg;
    var first = true;
    while (true) {
        const len = getOneLine(rest);
        const line = trimmed(rest[0..len]);
        rest = rest[len..];
        if (len == 0 or line.len == 0) break;
        if (!first) try out.append(a, ' ');
        try out.appendSlice(a, line);
        first = false;
    }
    return rest;
}

/// git's `pp_remainder`: each line of the message, its trailing space
/// gone, indented four columns; the blank lines before the first left
/// out, and under `short` everything from the first after it.
fn remainder(a: Allocator, out: *std.ArrayList(u8), msg: []const u8, fmt: Builtin, tabs: usize) Allocator.Error!void {
    var rest = msg;
    var first = true;
    while (true) {
        const len = getOneLine(rest);
        if (len == 0) break;
        const line = trimmed(rest[0..len]);
        rest = rest[len..];
        if (line.len == 0) {
            if (first) continue;
            if (fmt == .short) break;
        }
        first = false;
        try out.appendNTimes(a, ' ', 4);
        if (tabs != 0) try tabExpand(a, out, line, tabs) else try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
}

/// git's `strbuf_add_tabexpand`: each tab to the next multiple of `tabs`
/// columns of what came since the last, until a run whose width is not
/// UTF-8's to say, from which the line is written as it stands.
fn tabExpand(a: Allocator, out: *std.ArrayList(u8), text: []const u8, tabs: usize) Allocator.Error!void {
    var line = text;
    while (std.mem.findScalar(u8, line, '\t')) |tab| {
        const width = runWidth(line[0..tab]) orelse break;
        try out.appendSlice(a, line[0..tab]);
        try out.appendNTimes(a, ' ', tabs - (width % tabs));
        line = line[tab + 1 ..];
    }
    try out.appendSlice(a, line);
}

/// git's `pp_utf8_width`: `null` for bytes that are not UTF-8 or a
/// character with no width to give.
fn runWidth(run: []const u8) ?usize {
    var width: usize = 0;
    var rest = run;
    while (rest.len > 0) {
        const cp = unicode_width.decode(rest) orelse return null;
        const w = unicode_width.width(cp.char);
        if (w < 0) return null;
        width += @intCast(w);
        rest = rest[cp.len..];
    }
    return width;
}

/// A line without its trailing space and line end: git's `is_blank_line`
/// cut.
fn trimmed(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and ctype.isSpace(line[end - 1])) end -= 1;
    return line[0..end];
}

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

fn skipBlankLines(msg: []const u8) []const u8 {
    var rest = msg;
    while (true) {
        const len = getOneLine(rest);
        if (len == 0 or trimmed(rest[0..len]).len != 0) break;
        rest = rest[len..];
    }
    return rest;
}
