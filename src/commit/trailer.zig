//! Trailers: the `Key: value` lines at the end of a commit message, as
//! git's `trailer.c` finds, reads, adds and writes them.
//!
//! The block is the last paragraph when every line of it is a trailer, or
//! when a quarter of it is and one line is git's own (`Signed-off-by: `,
//! `(cherry picked from commit `) or a configured name; the title is never
//! a trailer, and a `---` divider, trailing comments and a scissors line end
//! the message before it. `trailer.separators`, `trailer.where`,
//! `trailer.ifExists`, `trailer.ifMissing` and every `trailer.<name>.key`,
//! `.where`, `.ifExists`, `.ifMissing`, `.command` and `.cmd` are read as
//! git reads them: a name matches a token by its prefix and without case,
//! a key replaces the token it matches, and a command's output is the
//! value. `process` is `git interpret-trailers`; `format` is what `%(trailers)`
//! writes; `iterate` is git's `trailer_iterator`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config_mod = @import("../config.zig");
const program = @import("../repo/program.zig");
const fs = @import("../repo/fs.zig");

/// Errors from adding trailers.
pub const Error = error{
    /// A `trailer.<name>.command` or `.cmd` applies and no `Programs` were
    /// given to run it.
    TrailerCommandNeedsPrograms,
} || Allocator.Error || program.Error;

/// Where a new trailer goes: `--where`, `trailer.where`.
pub const Where = enum {
    end,
    after,
    before,
    start,

    /// git's `trailer_set_where`, which ignores case.
    pub fn parse(text: []const u8) ?Where {
        inline for (.{ "after", "before", "end", "start" }) |name| {
            if (std.ascii.eqlIgnoreCase(text, name)) return @field(Where, name);
        }
        return null;
    }

    fn afterOrEnd(w: Where) bool {
        return w == .after or w == .end;
    }
};

/// What happens to a new trailer whose token is already there:
/// `--if-exists`, `trailer.ifExists`.
pub const IfExists = enum {
    add_if_different_neighbor,
    add_if_different,
    add,
    replace,
    do_nothing,

    /// git's `trailer_set_if_exists`, which ignores case.
    pub fn parse(text: []const u8) ?IfExists {
        if (std.ascii.eqlIgnoreCase(text, "addIfDifferent")) return .add_if_different;
        if (std.ascii.eqlIgnoreCase(text, "addIfDifferentNeighbor")) return .add_if_different_neighbor;
        if (std.ascii.eqlIgnoreCase(text, "add")) return .add;
        if (std.ascii.eqlIgnoreCase(text, "replace")) return .replace;
        if (std.ascii.eqlIgnoreCase(text, "doNothing")) return .do_nothing;
        return null;
    }
};

/// What happens to a new trailer whose token is not there: `--if-missing`,
/// `trailer.ifMissing`.
pub const IfMissing = enum {
    add,
    do_nothing,

    /// git's `trailer_set_if_missing`, which ignores case.
    pub fn parse(text: []const u8) ?IfMissing {
        if (std.ascii.eqlIgnoreCase(text, "doNothing")) return .do_nothing;
        if (std.ascii.eqlIgnoreCase(text, "add")) return .add;
        return null;
    }
};

/// One `trailer.<name>.*` section: git's `conf_info`.
pub const Rule = struct {
    name: []const u8,
    /// `trailer.<name>.key`: the token a matching trailer is written with.
    key: ?[]const u8 = null,
    /// `trailer.<name>.command`: a shell command, `$ARG` replaced by the
    /// value, whose output is the value. Added to every message.
    command: ?[]const u8 = null,
    /// `trailer.<name>.cmd`: a shell command given the value as its
    /// argument, whose output is the value.
    cmd: ?[]const u8 = null,
    where: Where,
    if_exists: IfExists,
    if_missing: IfMissing,
};

/// How trailers are read and added: the `trailer.*` configuration and the
/// comment string.
pub const Settings = struct {
    /// `core.commentChar` or `core.commentString`.
    comment: []const u8 = "#",
    /// `trailer.separators`: the characters that end a token.
    separators: []const u8 = ":",
    where: Where = .end,
    if_exists: IfExists = .add_if_different_neighbor,
    if_missing: IfMissing = .add,
    rules: []const Rule = &.{},

    /// git's `trailer_config_init`: the defaults (`trailer.where`,
    /// `.ifexists`, `.ifmissing`, `.separators`) first, then each
    /// `trailer.<name>.<variable>` in the order the files give them, a
    /// name's section made the first time it is named, without case, from
    /// the defaults. A value git does not know is ignored, as git warns and
    /// ignores it. Everything is `arena`'s.
    pub fn load(arena: Allocator, config: *const config_mod.Config, comment: []const u8) Allocator.Error!Settings {
        var s: Settings = .{ .comment = comment };
        for (config.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.section, "trailer") or entry.has_subsection) continue;
            const value = try decoded(arena, entry.value) orelse continue;
            if (std.mem.eql(u8, entry.name, "where")) {
                if (Where.parse(value)) |w| s.where = w;
            } else if (std.mem.eql(u8, entry.name, "ifexists")) {
                if (IfExists.parse(value)) |e| s.if_exists = e;
            } else if (std.mem.eql(u8, entry.name, "ifmissing")) {
                if (IfMissing.parse(value)) |m| s.if_missing = m;
            } else if (std.mem.eql(u8, entry.name, "separators")) {
                s.separators = value;
            }
        }
        var rules: std.ArrayList(Rule) = .empty;
        for (config.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.section, "trailer") or !entry.has_subsection) continue;
            const known = for ([_][]const u8{ "key", "command", "cmd", "where", "ifexists", "ifmissing" }) |name| {
                if (std.mem.eql(u8, entry.name, name)) break true;
            } else false;
            if (!known) continue;
            const rule = for (rules.items) |*r| {
                if (std.ascii.eqlIgnoreCase(r.name, entry.subsection)) break r;
            } else blk: {
                try rules.append(arena, .{
                    .name = try arena.dupe(u8, entry.subsection),
                    .where = s.where,
                    .if_exists = s.if_exists,
                    .if_missing = s.if_missing,
                });
                break :blk &rules.items[rules.items.len - 1];
            };
            const value = try decoded(arena, entry.value);
            if (std.mem.eql(u8, entry.name, "key")) {
                rule.key = value orelse continue;
            } else if (std.mem.eql(u8, entry.name, "command")) {
                rule.command = value orelse continue;
            } else if (std.mem.eql(u8, entry.name, "cmd")) {
                rule.cmd = value orelse continue;
            } else if (std.mem.eql(u8, entry.name, "where")) {
                rule.where = if (value) |v| Where.parse(v) orelse rule.where else s.where;
            } else if (std.mem.eql(u8, entry.name, "ifexists")) {
                rule.if_exists = if (value) |v| IfExists.parse(v) orelse rule.if_exists else s.if_exists;
            } else if (std.mem.eql(u8, entry.name, "ifmissing")) {
                rule.if_missing = if (value) |v| IfMissing.parse(v) orelse rule.if_missing else s.if_missing;
            }
        }
        s.rules = rules.items;
        return s;
    }
};

fn decoded(arena: Allocator, raw: ?[]const u8) Allocator.Error!?[]const u8 {
    const text = raw orelse return null;
    return config_mod.unquote(arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => text,
    };
}

/// What `process` and `format` write: git's `process_trailer_options`.
pub const Options = struct {
    /// `--trim-empty`: a trailer with no value is left out.
    trim_empty: bool = false,
    /// `--only-trailers`: the trailers and nothing else.
    only_trailers: bool = false,
    /// `--only-input`: no trailer added, from the arguments or the
    /// configuration.
    only_input: bool = false,
    /// `--unfold`: a value carried over continuation lines on one line.
    unfold: bool = false,
    /// `--no-divider`: a `---` line does not end the message.
    no_divider: bool = false,
    /// `keyonly` and `valueonly`.
    key_only: bool = false,
    value_only: bool = false,
    /// `separator=`: between trailers, rather than each on its own line.
    separator: ?[]const u8 = null,
    /// `key_value_separator=`: between a key and its value.
    key_value_separator: ?[]const u8 = null,
    /// `key=`: only trailers with one of these keys, without case; a key's
    /// own trailing `:` is not part of it.
    keys: ?[]const []const u8 = null,

    /// `--parse`: only the trailers, nothing added, values unfolded.
    pub const parse: Options = .{ .only_trailers = true, .only_input = true, .unfold = true };
};

/// One `--trailer` argument, with the `--where`, `--if-exists` and
/// `--if-missing` in force where it was given.
pub const New = struct {
    /// `<key>`, `<key>=<value>` or `<key><separator><value>`.
    text: []const u8,
    where: ?Where = null,
    if_exists: ?IfExists = null,
    if_missing: ?IfMissing = null,
};

/// What runs `trailer.<name>.command` and `.cmd`.
pub const Commands = struct {
    programs: program.Programs,
    /// Where the commands run; the process's own directory when `.inherit`.
    cwd: std.process.Child.Cwd = .inherit,
};

// ---------------------------------------------------------------------------
// reading
// ---------------------------------------------------------------------------

/// git's `isspace`: space, tab, newline and carriage return.
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn charAt(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

/// C's `strncasecmp(a, b, n) == 0` over slices that end like C strings.
fn equalPrefixIgnoreCase(a: []const u8, b: []const u8, n: usize) bool {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x = std.ascii.toLower(charAt(a, i));
        const y = std.ascii.toLower(charAt(b, i));
        if (x != y) return false;
        if (x == 0) return true;
    }
    return true;
}

fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and isSpace(text[start])) start += 1;
    while (end > start and isSpace(text[end - 1])) end -= 1;
    return text[start..end];
}

/// The length of `token` without its final punctuation: git's
/// `token_len_without_separator`.
fn tokenLen(token: []const u8) usize {
    var len = token.len;
    while (len > 0 and !std.ascii.isAlphanumeric(token[len - 1])) len -= 1;
    return len;
}

/// git's `find_separator`: where a line of `<token><optional
/// whitespace><separator>` has its separator, `0` for a line that starts
/// with one, `null` for one that is not a trailer. A separator that begins
/// `://` straight after the token is a URL's, as git 2.56 reads it.
pub fn findSeparator(line: []const u8, separators: []const u8) ?usize {
    var whitespace_found = false;
    for (line, 0..) |c, i| {
        if (c == 0) break;
        if (std.mem.indexOfScalar(u8, separators, c) != null) {
            if (!whitespace_found and std.mem.startsWith(u8, line[i..], "://")) return null;
            return i;
        }
        if (!whitespace_found and (std.ascii.isAlphanumeric(c) or c == '-')) continue;
        if (i != 0 and (c == ' ' or c == '\t')) {
            whitespace_found = true;
            continue;
        }
        break;
    }
    return null;
}

fn tokenMatchesRule(token: []const u8, rule: Rule, len: usize) bool {
    if (equalPrefixIgnoreCase(token, rule.name, len)) return true;
    if (rule.key) |key| return equalPrefixIgnoreCase(token, key, len);
    return false;
}

fn nextLine(buf: []const u8, at: usize) usize {
    const nl = std.mem.indexOfScalarPos(u8, buf, at, '\n') orelse return buf.len;
    return nl + 1;
}

/// git's `last_line`: where the last line of `buf[0..len]` starts, `null`
/// when it is empty.
fn lastLine(buf: []const u8, len: usize) ?usize {
    if (len == 0) return null;
    if (len == 1) return 0;
    var i: usize = len - 1;
    while (i > 0) {
        i -= 1;
        if (buf[i] == '\n') return i + 1;
    }
    return 0;
}

fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c == '\n') return true;
        if (!isSpace(c)) return false;
    }
    return true;
}

const generated_prefixes = [_][]const u8{ "Signed-off-by: ", "(cherry picked from commit " };

/// The line `git commit -v` cuts a message at, after the comment string
/// and a space.
const cut_line = "------------------------ >8 ------------------------";

/// git's `wt_status_locate_end`: where a scissors line cuts the message.
fn locateEnd(s: []const u8, comment: []const u8, len_in: usize) usize {
    var len = len_in;
    var pattern_buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\n{s} {s}", .{ comment, cut_line }) catch return len;
    if (std.mem.startsWith(u8, s, pattern[1..])) {
        len = 0;
    } else if (std.mem.indexOf(u8, s, pattern)) |p| {
        const newlen = p + 1;
        if (newlen < len) len = newlen;
    }
    return len;
}

/// git's `ignored_log_message_bytes`: the comments, blank lines and old
/// `Conflicts:` block at the end of `buf[0..len]`, and what follows a
/// scissors line.
pub fn ignoredBytes(buf: []const u8, len: usize, comment: []const u8) usize {
    var boc: usize = 0;
    var bol: usize = 0;
    var in_old_conflicts_block = false;
    const cutoff = locateEnd(buf[0..len], comment, len);
    while (bol < cutoff) {
        const next = nextLine(buf[0..len], bol);
        if (std.mem.startsWith(u8, buf[bol..cutoff], comment) or buf[bol] == '\n') {
            if (boc == 0) boc = bol;
        } else if (std.mem.startsWith(u8, buf[bol..len], "Conflicts:\n")) {
            in_old_conflicts_block = true;
            if (boc == 0) boc = bol;
        } else if (in_old_conflicts_block and buf[bol] == '\t') {
            // a path in the conflicts block
        } else if (boc != 0) {
            boc = 0;
            in_old_conflicts_block = false;
        }
        bol = next;
    }
    return if (boc != 0) len - boc else len - cutoff;
}

/// git's `find_end_of_log_message`.
fn endOfLogMessage(input_in: []const u8, no_divider: bool, comment: []const u8) usize {
    const input = cStr(input_in);
    var end = input.len;
    if (!no_divider) {
        var s: usize = 0;
        while (s < input.len) : (s = nextLine(input, s)) {
            if (std.mem.startsWith(u8, input[s..], "---") and isSpace(charAt(input, s + 3))) {
                end = s;
                break;
            }
        }
    }
    return end - ignoredBytes(input, end, comment);
}

fn cStr(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, 0)) |z| s[0..z] else s;
}

/// git's `find_trailer_block_start`: where the trailers of `buf[0..len]`
/// begin, `len` when there are none.
fn blockStart(settings: Settings, buf: []const u8, len: usize) usize {
    const comment = settings.comment;
    var s: usize = 0;
    while (s < len) : (s = nextLine(buf[0..len], s)) {
        if (std.mem.startsWith(u8, buf[s..len], comment)) continue;
        if (isBlankLine(buf[s..len])) break;
    }
    const end_of_title = s;
    var only_spaces = true;
    var recognized_prefix = false;
    var trailer_lines: usize = 0;
    var non_trailer_lines: usize = 0;
    var possible_continuation_lines: usize = 0;
    var cursor = lastLine(buf, len);
    while (cursor) |l| : (cursor = lastLine(buf, l)) {
        if (l < end_of_title) break;
        const bol = buf[l..len];
        if (std.mem.startsWith(u8, bol, comment)) {
            non_trailer_lines += possible_continuation_lines;
            possible_continuation_lines = 0;
            if (l == 0) break;
            continue;
        }
        if (isBlankLine(bol)) {
            if (only_spaces) {
                if (l == 0) break;
                continue;
            }
            non_trailer_lines += possible_continuation_lines;
            if (recognized_prefix and trailer_lines * 3 >= non_trailer_lines) return nextLine(buf[0..len], l);
            if (trailer_lines != 0 and non_trailer_lines == 0) return nextLine(buf[0..len], l);
            return len;
        }
        only_spaces = false;
        const generated = for (generated_prefixes) |prefix| {
            if (std.mem.startsWith(u8, buf[l..], prefix)) break true;
        } else false;
        if (generated) {
            trailer_lines += 1;
            possible_continuation_lines = 0;
            recognized_prefix = true;
        } else if (findSeparator(buf[l..], settings.separators)) |sep| {
            if (sep >= 1 and !isSpace(bol[0])) {
                trailer_lines += 1;
                possible_continuation_lines = 0;
                if (!recognized_prefix) {
                    for (settings.rules) |rule| {
                        if (tokenMatchesRule(buf[l..], rule, sep)) {
                            recognized_prefix = true;
                            break;
                        }
                    }
                }
            } else if (isSpace(bol[0])) {
                possible_continuation_lines += 1;
            } else {
                non_trailer_lines += 1 + possible_continuation_lines;
                possible_continuation_lines = 0;
            }
        } else if (isSpace(bol[0])) {
            possible_continuation_lines += 1;
        } else {
            non_trailer_lines += 1 + possible_continuation_lines;
            possible_continuation_lines = 0;
        }
        if (l == 0) break;
    }
    return len;
}

/// Where a message's trailers are, and their lines.
pub const Block = struct {
    /// Whether a blank line comes before `start`.
    blank_line_before: bool,
    start: usize,
    end: usize,
    /// The block's lines, each with its newline, a continuation line
    /// joined to the trailer above it.
    lines: []const []const u8,
};

/// git's `trailer_block_get`.
pub fn block(arena: Allocator, settings: Settings, msg_in: []const u8, no_divider: bool) Allocator.Error!Block {
    const msg = cStr(msg_in);
    const end = endOfLogMessage(msg, no_divider, settings.comment);
    const start = blockStart(settings, msg, end);
    var lines: std.ArrayList([]const u8) = .empty;
    var last: ?usize = null;
    var at = start;
    while (at < end) {
        const next = @min(nextLine(msg, at), end);
        const piece = msg[at..next];
        at = next;
        if (last != null and isSpace(piece[0])) {
            lines.items[last.?] = try std.mem.concat(arena, u8, &.{ lines.items[last.?], piece });
            continue;
        }
        try lines.append(arena, piece);
        last = if (findSeparator(piece, settings.separators)) |sep| (if (sep >= 1) lines.items.len - 1 else null) else null;
    }
    const ll = lastLine(msg, start);
    return .{
        .blank_line_before = if (ll) |l| isBlankLine(msg[l..start]) else false,
        .start = start,
        .end = end,
        .lines = lines.items,
    };
}

/// git's `unfold_value`.
fn unfold(arena: Allocator, value: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        var c = value[i];
        i += 1;
        if (c == '\n') {
            while (i < value.len and isSpace(value[i])) i += 1;
            c = ' ';
        }
        try out.append(arena, c);
    }
    return trim(out.items);
}

/// A token and value read from a line, the token as a matching rule's key
/// spells it: git's `parse_trailer`.
const Parsed = struct { token: []const u8, value: []const u8, rule: ?*const Rule };

fn parseTrailer(settings: Settings, text: []const u8, separator: ?usize) Parsed {
    var token: []const u8 = undefined;
    var value: []const u8 = "";
    if (separator) |sep| {
        token = trim(text[0..sep]);
        value = trim(text[sep + 1 ..]);
    } else token = trim(text);
    const len = tokenLen(token);
    for (settings.rules) |*rule| {
        if (tokenMatchesRule(token, rule.*, len)) {
            return .{ .token = rule.key orelse token, .value = value, .rule = rule };
        }
    }
    return .{ .token = token, .value = value, .rule = null };
}

/// One line of the block as git's iterator reads it.
pub const Trailer = struct {
    /// The line as it stands.
    raw: []const u8,
    key: []const u8,
    value: []const u8,
};

/// git's `trailer_iterator`: each line of `msg`'s trailer block, its key
/// and its unfolded value, read with no `---` divider. Everything is
/// `arena`'s.
pub fn iterate(arena: Allocator, settings: Settings, msg: []const u8) Allocator.Error![]Trailer {
    const b = try block(arena, settings, msg, true);
    const out = try arena.alloc(Trailer, b.lines.len);
    for (b.lines, out) |line, *t| {
        const parsed = parseTrailer(settings, line, findSeparator(line, settings.separators));
        t.* = .{ .raw = line, .key = parsed.token, .value = try unfold(arena, parsed.value) };
    }
    return out;
}

// ---------------------------------------------------------------------------
// writing
// ---------------------------------------------------------------------------

const Item = struct {
    /// `null` for a line of the block that is not a trailer.
    token: ?[]const u8,
    value: []const u8,
};

const Arg = struct {
    token: []const u8,
    value: []const u8,
    rule: Rule,
};

fn parseItems(arena: Allocator, settings: Settings, options: Options, b: Block) Allocator.Error!std.ArrayList(Item) {
    var items: std.ArrayList(Item) = .empty;
    for (b.lines) |line| {
        if (std.mem.startsWith(u8, line, settings.comment)) continue;
        const sep = findSeparator(line, settings.separators);
        if (sep != null and sep.? >= 1) {
            const parsed = parseTrailer(settings, line, sep);
            const value = if (options.unfold) try unfold(arena, parsed.value) else parsed.value;
            try items.append(arena, .{ .token = parsed.token, .value = value });
        } else if (!options.only_trailers) {
            try items.append(arena, .{ .token = null, .value = if (std.mem.endsWith(u8, line, "\n")) line[0 .. line.len - 1] else line });
        }
    }
    return items;
}

fn lastNonSpace(s: []const u8) u8 {
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (!isSpace(s[i])) return s[i];
    }
    return 0;
}

fn keyWanted(options: Options, token: []const u8) bool {
    const keys = options.keys orelse return true;
    for (keys) |key_in| {
        var key = key_in;
        if (key.len != 0 and key[key.len - 1] == ':') key = key[0 .. key.len - 1];
        if (key.len == token.len and std.ascii.eqlIgnoreCase(key, token)) return true;
    }
    return false;
}

/// git's `format_trailers`.
fn formatItems(gpa: Allocator, settings: Settings, options: Options, items: []const Item, out: *std.ArrayList(u8)) Allocator.Error!void {
    const origlen = out.items.len;
    for (items) |item| {
        if (item.token) |token| {
            if (options.trim_empty and item.value.len == 0) continue;
            if (!keyWanted(options, token)) continue;
            if (options.separator) |sep| if (out.items.len != origlen) try out.appendSlice(gpa, sep);
            if (!options.value_only) try out.appendSlice(gpa, token);
            if (!options.key_only and !options.value_only) {
                if (options.key_value_separator) |kv| {
                    try out.appendSlice(gpa, kv);
                } else {
                    const c = lastNonSpace(token);
                    if (c != 0 and std.mem.indexOfScalar(u8, settings.separators, c) == null) {
                        try out.append(gpa, settings.separators[0]);
                        try out.append(gpa, ' ');
                    }
                }
            }
            if (!options.key_only) try out.appendSlice(gpa, item.value);
            if (options.separator == null) try out.append(gpa, '\n');
        } else if (!options.only_trailers) {
            if (options.separator) |sep| if (out.items.len != origlen) try out.appendSlice(gpa, sep);
            try out.appendSlice(gpa, item.value);
            if (options.separator != null) {
                while (out.items.len > 0 and isSpace(out.items[out.items.len - 1])) _ = out.pop();
            } else try out.append(gpa, '\n');
        }
    }
}

/// What `%(trailers)` writes for `msg`, a message from its subject on:
/// git's `format_trailers_from_commit`. The block as it stands when no
/// option reshapes it.
pub fn format(gpa: Allocator, settings: Settings, options: Options, msg: []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const b = try block(arena, settings, msg, options.no_divider);
    if (!options.only_trailers and !options.unfold and options.keys == null and options.separator == null and
        !options.key_only and !options.value_only and options.key_value_separator == null)
    {
        try out.appendSlice(gpa, msg[b.start..b.end]);
        return;
    }
    const items = try parseItems(arena, settings, options, b);
    try formatItems(gpa, settings, options, items.items, out);
}

/// git's `apply_command`: the value a rule's command gives for `arg`, or
/// the empty string when it fails.
fn applyCommand(arena: Allocator, io: Io, commands: ?Commands, rule: Rule, arg: []const u8) Error![]const u8 {
    const run_with = commands orelse return error.TrailerCommandNeedsPrograms;
    var argv: std.ArrayList([]const u8) = .empty;
    if (rule.cmd) |cmd| {
        try argv.append(arena, cmd);
        try argv.append(arena, arg);
    } else if (rule.command) |command| {
        var line = command;
        if (std.mem.indexOf(u8, command, "$ARG")) |at| {
            line = try std.mem.concat(arena, u8, &.{ command[0..at], arg, command[at + 4 ..] });
        }
        try argv.append(arena, line);
    }
    var outcome = program.run(run_with.programs, arena, io, .{
        .argv = argv.items,
        .shell = true,
        .cwd = run_with.cwd,
        .unset = &program.repository_variables,
        .stderr = .inherit,
    }, "", .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return "",
    };
    if (!outcome.succeeded()) return "";
    return trim(outcome.stdout);
}

/// git's `apply_item_command`.
fn applyItemCommand(arena: Allocator, io: Io, commands: ?Commands, in_value: ?[]const u8, arg: *Arg) Error!void {
    if (arg.rule.command == null and arg.rule.cmd == null) return;
    const text = if (arg.value.len != 0) arg.value else in_value orelse "";
    arg.value = try applyCommand(arena, io, commands, arg.rule, text);
}

fn sameToken(item: Item, arg: Arg) bool {
    const token = item.token orelse return false;
    const a = tokenLen(token);
    const b = tokenLen(arg.token);
    return equalPrefixIgnoreCase(token, arg.token, @min(a, b));
}

fn sameTrailer(item: Item, arg: Arg) bool {
    return sameToken(item, arg) and std.ascii.eqlIgnoreCase(item.value, arg.value);
}

/// git's `check_if_different`, from `at` towards the start for a trailer
/// going after or at the end, towards the end otherwise.
fn isDifferent(items: []const Item, at_in: usize, arg: Arg, check_all: bool) bool {
    var at = at_in;
    while (true) {
        if (sameTrailer(items[at], arg)) return false;
        if (arg.rule.where.afterOrEnd()) {
            if (at == 0) break;
            at -= 1;
        } else {
            if (at + 1 >= items.len) break;
            at += 1;
        }
        if (!check_all) break;
    }
    return true;
}

/// git's `add_arg_to_input_list`: after `on` for a trailer going after or
/// at the end, before it otherwise.
fn addNear(arena: Allocator, items: *std.ArrayList(Item), on: usize, arg: Arg) Allocator.Error!void {
    const item: Item = .{ .token = arg.token, .value = arg.value };
    if (arg.rule.where.afterOrEnd()) try items.insert(arena, on + 1, item) else try items.insert(arena, on, item);
}

/// git's `process_trailers_lists`.
fn apply(arena: Allocator, io: Io, commands: ?Commands, items: *std.ArrayList(Item), args: []Arg) Error!void {
    for (args) |*arg| {
        const where = arg.rule.where;
        const middle = where == .after or where == .before;
        const backwards = where.afterOrEnd();
        var found: ?usize = null;
        if (items.items.len != 0) {
            var i: usize = 0;
            while (i < items.items.len) : (i += 1) {
                const at = if (backwards) items.items.len - 1 - i else i;
                if (sameToken(items.items[at], arg.*)) {
                    found = at;
                    break;
                }
            }
        }
        if (found) |in_at| {
            const start: usize = if (backwards) items.items.len - 1 else 0;
            const on = if (middle) in_at else start;
            switch (arg.rule.if_exists) {
                .do_nothing => {},
                .replace => {
                    try applyItemCommand(arena, io, commands, items.items[in_at].value, arg);
                    try addNear(arena, items, on, arg.*);
                    // the new one went before or after; the old one moved
                    // by one where it went before it
                    const old = if (!where.afterOrEnd() and on <= in_at) in_at + 1 else in_at;
                    _ = items.orderedRemove(old);
                },
                .add => {
                    try applyItemCommand(arena, io, commands, items.items[in_at].value, arg);
                    try addNear(arena, items, on, arg.*);
                },
                .add_if_different => {
                    try applyItemCommand(arena, io, commands, items.items[in_at].value, arg);
                    if (isDifferent(items.items, in_at, arg.*, true)) try addNear(arena, items, on, arg.*);
                },
                .add_if_different_neighbor => {
                    try applyItemCommand(arena, io, commands, items.items[in_at].value, arg);
                    if (isDifferent(items.items, on, arg.*, false)) try addNear(arena, items, on, arg.*);
                },
            }
        } else switch (arg.rule.if_missing) {
            .do_nothing => {},
            .add => {
                try applyItemCommand(arena, io, commands, null, arg);
                const item: Item = .{ .token = arg.token, .value = arg.value };
                if (where.afterOrEnd()) try items.append(arena, item) else try items.insert(arena, 0, item);
            },
        }
    }
}

fn ruleFor(settings: Settings, parsed: Parsed) Rule {
    if (parsed.rule) |r| return r.*;
    return .{ .name = "", .where = settings.where, .if_exists = settings.if_exists, .if_missing = settings.if_missing };
}

/// `git interpret-trailers`: `input` with its trailers read, the ones
/// `new` names and the configured commands add placed as `trailer.*` and
/// the arguments say, and the block written back: git's
/// `process_trailers`. A `--trailer` with no token before its separator is
/// left out, as git reports and leaves it. `commands` runs
/// `trailer.<name>.command` and `.cmd`; without it, one that applies is
/// `error.TrailerCommandNeedsPrograms`.
pub fn process(gpa: Allocator, io: Io, settings: Settings, commands: ?Commands, options: Options, new: []const New, input: []const u8, out: *std.ArrayList(u8)) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const b = try block(arena, settings, input, options.no_divider);
    var items = try parseItems(arena, settings, options, b);
    if (!options.only_trailers) try out.appendSlice(gpa, input[0..b.start]);
    if (!options.only_trailers and !b.blank_line_before) try out.append(gpa, '\n');
    if (!options.only_input) {
        var args: std.ArrayList(Arg) = .empty;
        // the configured commands first, then the arguments
        for (settings.rules) |rule| {
            if (rule.command == null) continue;
            try args.append(arena, .{ .token = rule.key orelse rule.name, .value = "", .rule = rule });
        }
        const cl_separators = try std.mem.concat(arena, u8, &.{ "=", settings.separators });
        for (new) |n| {
            const sep = findSeparator(n.text, cl_separators);
            if (sep != null and sep.? == 0) continue;
            const parsed = parseTrailer(settings, n.text, sep);
            var rule = ruleFor(settings, parsed);
            if (n.where) |w| rule.where = w;
            if (n.if_exists) |e| rule.if_exists = e;
            if (n.if_missing) |m| rule.if_missing = m;
            try args.append(arena, .{ .token = parsed.token, .value = parsed.value, .rule = rule });
        }
        try apply(arena, io, commands, &items, args.items);
    }
    try formatItems(gpa, settings, options, items.items, out);
    if (!options.only_trailers) try out.appendSlice(gpa, input[b.end..]);
}

/// Errors from processing a file.
pub const FileError = Error || fs.AtomicWriteError || Io.Dir.ReadFileAllocError || Io.Dir.OpenError ||
    Io.File.StatError || Io.Dir.SetFilePermissionsError;

/// `git interpret-trailers <file>`, or `--in-place`: the file read, ended
/// with a newline as git ends it, and processed; with `in_place` the result
/// replaces the file, keeping its permissions, through a new file beside it,
/// and otherwise it is appended to `out`.
pub fn processFile(gpa: Allocator, io: Io, settings: Settings, commands: ?Commands, options: Options, new: []const New, dir: Io.Dir, path: []const u8, in_place: bool, out: *std.ArrayList(u8)) FileError!void {
    var input: std.ArrayList(u8) = .fromOwnedSlice(try dir.readFileAlloc(io, path, gpa, .unlimited));
    defer input.deinit(gpa);
    try completeLine(gpa, &input);
    if (!in_place) return process(gpa, io, settings, commands, options, new, input.items, out);
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(gpa);
    try process(gpa, io, settings, commands, options, new, input.items, &result);
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\");
    var parent = if (slash) |at| try dir.openDir(io, path[0..at], .{}) else dir;
    defer if (slash != null) parent.close(io);
    const base = if (slash) |at| path[at + 1 ..] else path;
    const stat = try parent.statFile(io, base, .{});
    var name_buf: [128]u8 = undefined;
    const temp = fs.tempName(io, &name_buf, "git-interpret-trailers-");
    var file = try parent.createFile(io, temp, .{ .exclusive = true });
    errdefer {
        file.close(io);
        parent.deleteFile(io, temp) catch {};
    }
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &write_buf);
    try fw.interface.writeAll(result.items);
    try fw.interface.flush();
    file.close(io);
    fs.setFilePermissions(io, parent, temp, stat.permissions) catch {};
    fs.renameWithRetry(io, parent, temp, base) catch |err| {
        parent.deleteFile(io, temp) catch {};
        return err;
    };
}

/// git's `strbuf_complete_line`.
fn completeLine(gpa: Allocator, buf: *std.ArrayList(u8)) Allocator.Error!void {
    if (buf.items.len != 0 and buf.items[buf.items.len - 1] != '\n') try buf.append(gpa, '\n');
}

/// What `git commit --trailer` does to a message: git's
/// `amend_strbuf_with_trailers`, which reads no `---` divider. The result
/// is `gpa`'s.
pub fn amend(gpa: Allocator, io: Io, settings: Settings, commands: ?Commands, message: []const u8, trailers: []const []const u8) Error![]u8 {
    var new: std.ArrayList(New) = .empty;
    defer new.deinit(gpa);
    for (trailers) |text| try new.append(gpa, .{ .text = text });
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try process(gpa, io, settings, commands, .{ .no_divider = true }, new.items, message, &out);
    return out.toOwnedSlice(gpa);
}

/// git's `format_set_trailers_options`: the options of `%(trailers:...)`,
/// `text` being what follows the colon up to and including the closing
/// parenthesis. Returns the options and how much of `text` they took, the
/// parenthesis excluded; `null` where git refuses them. Values are
/// `arena`'s.
pub fn parsePlaceholderOptions(arena: Allocator, text: []const u8) Allocator.Error!?struct { options: Options, len: usize } {
    var options: Options = .{};
    var keys: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (true) {
        if (at < text.len and text[at] == ')') break;
        const rest = text[at..];
        if (matchArg(rest, "key")) |m| {
            const value = m.value orelse return null;
            try keys.append(arena, value);
            options.only_trailers = true;
            at += m.len;
        } else if (matchArg(rest, "separator")) |m| {
            options.separator = try expandArg(arena, m.value orelse "");
            if (m.value == null) options.separator = null;
            at += m.len;
        } else if (matchArg(rest, "key_value_separator")) |m| {
            options.key_value_separator = try expandArg(arena, m.value orelse "");
            if (m.value == null) options.key_value_separator = null;
            at += m.len;
        } else if (matchBool(rest, "only", &options.only_trailers) orelse
            matchBool(rest, "unfold", &options.unfold) orelse
            matchBool(rest, "keyonly", &options.key_only) orelse
            matchBool(rest, "valueonly", &options.value_only)) |len|
        {
            at += len;
        } else return null;
    }
    if (keys.items.len != 0) options.keys = keys.items;
    return .{ .options = options, .len = at };
}

/// git's `match_placeholder_arg_value`: `name`, `name=value`, then a
/// comma (taken) or a closing parenthesis (left).
fn matchArg(text: []const u8, name: []const u8) ?struct { value: ?[]const u8, len: usize } {
    if (!std.mem.startsWith(u8, text, name)) return null;
    var p = name.len;
    var value: ?[]const u8 = null;
    if (p < text.len and text[p] == '=') {
        const start = p + 1;
        p = std.mem.indexOfAnyPos(u8, text, start, ",)") orelse text.len;
        value = text[start..p];
    } else if (p >= text.len or (text[p] != ',' and text[p] != ')')) return null;
    if (p < text.len and text[p] == ',') return .{ .value = value, .len = p + 1 };
    if (p < text.len and text[p] == ')') return .{ .value = value, .len = p };
    return null;
}

fn matchBool(text: []const u8, name: []const u8, out: *bool) ?usize {
    const m = matchArg(text, name) orelse return null;
    if (m.value) |v| {
        out.* = config_mod.parseBool(v) catch return null;
    } else out.* = true;
    return m.len;
}

/// git's `expand_string_arg`: `%%`, `%n` and `%xNN`.
fn expandArg(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        i += 1;
        if (c != '%') {
            try out.append(arena, c);
            continue;
        }
        if (i < text.len and text[i] == '%') {
            try out.append(arena, '%');
            i += 1;
        } else if (i < text.len and text[i] == 'n') {
            try out.append(arena, '\n');
            i += 1;
        } else if (i + 2 < text.len and text[i] == 'x') {
            const hi = std.fmt.charToDigit(text[i + 1], 16) catch {
                try out.append(arena, '%');
                continue;
            };
            const lo = std.fmt.charToDigit(text[i + 2], 16) catch {
                try out.append(arena, '%');
                continue;
            };
            try out.append(arena, hi << 4 | lo);
            i += 3;
        } else try out.append(arena, '%');
    }
    return out.items;
}
