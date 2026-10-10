//! Reading a patch the way `git apply` reads one: the files it changes, with
//! their names, modes and object names, and the hunks of each.
//!
//! Both kinds are read. A git patch — `diff --git` and its extended header:
//! modes, creation and deletion, renames and copies with their score, the
//! `index` line, and `GIT binary patch` hunks — and a traditional unified
//! diff, `---`/`+++` and `@@`, whose names are found with git's rules for
//! the timestamp after them and whose strip count is guessed from the first
//! file when the caller does not give one. Anything before, between and
//! after the patches is skipped, which is how a patch in an email or a
//! commit message is read.
//!
//! This file is git's `apply.c` from `find_header` to `parse_chunk`, line
//! for line where the rules are subtle: a hunk is as long as its counts say,
//! so a `---` inside it is not a new file; a `\ No newline` line belongs to
//! the line before it; an empty line is an empty context line. What is read
//! is a value; applying it is `apply.zig`'s.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const cquote = @import("../text.zig").cquote;
const binarypatch = @import("binary.zig");
const hunks = @import("parallax").patch;

/// Errors from reading a patch.
pub const Error = error{
    /// A hunk's lines do not add up to its `@@` counts, or a line in it
    /// begins with something no hunk line begins with: git's "corrupt
    /// patch".
    CorruptPatch,
    /// An `@@` line with no file header above it.
    FragmentWithoutHeader,
    /// A `diff --git` header from which no file name can be had.
    MissingFileName,
    /// Two of creation, deletion, rename and copy in one header.
    InconsistentHeader,
    /// A `---`/`+++` line in a git header that disagrees with the header.
    InconsistentFileName,
    /// A mode line that is not an octal number.
    InvalidMode,
    /// A `GIT binary patch` whose data does not decode or inflate.
    CorruptBinaryPatch,
    /// A `GIT binary patch` with no hunk under it.
    UnrecognizedBinaryPatch,
    /// A file header with no hunk and no change of name, mode or
    /// existence: git's "patch with only garbage".
    OnlyGarbage,
    /// A creation that removes lines, or a deletion that adds them.
    NewFileDependsOnOldContents,
    DeletedFileStillHasContents,
    /// Larger than the gigabyte git's own reader stops at.
    PatchTooLarge,
} || Allocator.Error;

/// The most a patch may be, git's `MAX_APPLY_SIZE`.
pub const max_patch_bytes: usize = 1024 * 1024 * 1023;

/// How a patch is read.
pub const Options = struct {
    /// `-p<n>`: leading path components removed from each name. `null` is
    /// git's default of one, with the count guessed from the first
    /// traditional patch's names, as git guesses it.
    strip: ?usize = null,
    /// `--directory`: prepended to every name, ending in `/`.
    root: []const u8 = "",
    /// `--recount`: the `@@` counts are recomputed from the lines.
    recount: bool = false,
    /// `--inaccurate-eof`: recorded on every file for `apply`.
    inaccurate_eof: bool = false,
    /// `-R`: the patch will be applied in reverse, so its added lines are
    /// the old file's, which decides whether the old file has CR LF.
    reverse: bool = false,
    /// Where the line a refusal was found at is written.
    diagnostic: ?*Diagnostic = null,
};

/// Where a patch was refused.
pub const Diagnostic = struct {
    /// The line, counting from one, that the refusal is about.
    line: usize = 0,
};

/// A file mode as a patch writes it, canonicalised as git canonicalises
/// one: `100644`, `100755`, `120000`, `160000`, or zero where the patch
/// says nothing.
pub const Mode = u32;

pub const mode_file: Mode = 0o100644;
pub const mode_exec: Mode = 0o100755;
pub const mode_symlink: Mode = 0o120000;
pub const mode_gitlink: Mode = 0o160000;
pub const mode_dir: Mode = 0o040000;

pub fn isRegular(mode: Mode) bool {
    return mode & 0o170000 == 0o100000;
}
pub fn isSymlink(mode: Mode) bool {
    return mode & 0o170000 == 0o120000;
}
pub fn isGitlink(mode: Mode) bool {
    return mode & 0o170000 == 0o160000;
}
/// The file type bits.
pub fn kind(mode: Mode) Mode {
    return mode & 0o170000;
}

fn canonMode(mode: u32) Mode {
    if (mode & 0o170000 == 0o100000) return if (mode & 0o100 != 0) mode_exec else mode_file;
    if (mode & 0o170000 == 0o120000) return mode_symlink;
    if (mode & 0o170000 == 0o040000) return mode_dir;
    return mode_gitlink;
}

/// One `@@` hunk.
pub const Fragment = struct {
    old_pos: usize,
    old_lines: usize,
    new_pos: usize,
    new_lines: usize,
    /// Context lines before the first change and after the last.
    leading: usize,
    trailing: usize,
    /// The hunk's text, its `@@` line included, borrowed from the patch.
    text: []const u8,
    /// The line of the patch the `@@` line is on.
    line: usize,
};

/// One side of a `GIT binary patch`.
pub const BinaryHunk = struct {
    method: binarypatch.Method,
    /// The inflated data: the whole file for `literal`, a delta for
    /// `delta`. Owned by the `Patch`.
    data: []const u8,
};

/// Unknown, no or yes: git's `-1`, `0`, `1` for whether a patch creates or
/// deletes, which a traditional patch leaves unknown until the hunks or
/// the working tree say.
pub const Tri = enum(i2) {
    unknown = -1,
    no = 0,
    yes = 1,

    pub fn isYes(t: Tri) bool {
        return t == .yes;
    }
};

/// What one file in a patch does.
pub const FilePatch = struct {
    /// Absent for a creation. Owned by the `Patch`.
    old_name: ?[]const u8 = null,
    /// Absent for a deletion.
    new_name: ?[]const u8 = null,
    old_mode: Mode = 0,
    new_mode: Mode = 0,
    is_new: Tri = .unknown,
    is_delete: Tri = .unknown,
    is_rename: bool = false,
    is_copy: bool = false,
    /// `similarity index` or `dissimilarity index`, as a percentage.
    score: u8 = 0,
    /// The hexadecimal object names on the `index` line, as written; empty
    /// when there is none.
    old_oid_prefix: []const u8 = "",
    new_oid_prefix: []const u8 = "",
    fragments: []Fragment = &.{},
    /// `GIT binary patch` or `Binary files ... differ`.
    is_binary: bool = false,
    /// The forward hunk and, when the patch carries one, the reverse.
    binary: ?struct { forward: BinaryHunk, reverse: ?BinaryHunk } = null,
    lines_added: usize = 0,
    lines_deleted: usize = 0,
    /// A context or removed line ends in CR LF, so the old file's line
    /// endings are compared as they are.
    crlf_in_old: bool = false,
    inaccurate_eof: bool = false,
    /// Names were taken from a git header and are relative to the top.
    toplevel_relative: bool = false,
    /// The line of the patch this file's header starts at.
    line: usize = 0,

    /// The name a message about this file uses: the old one where there
    /// is one, as git's `apply` says it.
    pub fn name(p: *const FilePatch) []const u8 {
        return p.old_name orelse p.new_name.?;
    }

    /// Whether the patch changes anything but content: a rename, a copy,
    /// a creation, a deletion or a mode.
    pub fn metadataChanges(p: *const FilePatch) bool {
        return p.is_rename or p.is_copy or p.is_new == .yes or p.is_delete != .no or
            (p.old_mode != 0 and p.new_mode != 0 and p.old_mode != p.new_mode);
    }
};

/// A parsed patch. Everything in it is owned by its arena; the text the
/// hunks borrow from is the caller's and must outlive it.
pub const Patch = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    files: []FilePatch,

    pub fn deinit(p: *Patch) void {
        p.arena.deinit();
        p.* = undefined;
    }
};

/// The parser's running state: git's `apply_state` fields that parsing
/// reads and writes.
const Parser = struct {
    a: Allocator,
    text: []const u8,
    options: Options,
    p_value: usize,
    p_value_known: bool,
    linenr: usize = 1,

    fn fail(p: *Parser, err: Error, line: usize) Error {
        if (p.options.diagnostic) |d| d.line = line;
        return err;
    }
};

/// Read every file patch in `text`.
///
/// Nothing in `text` that is not a patch is an error; a file header is.
/// An input with no patch in it at all gives an empty list.
pub fn parse(gpa: Allocator, text: []const u8, options: Options) Self.Error!Patch {
    if (text.len >= max_patch_bytes) return error.PatchTooLarge;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var p: Parser = .{
        .a = arena.allocator(),
        .text = text,
        .options = options,
        .p_value = options.strip orelse 1,
        .p_value_known = options.strip != null,
    };
    var files: std.ArrayList(FilePatch) = .empty;
    var offset: usize = 0;
    while (offset < text.len) {
        var file: FilePatch = .{ .inaccurate_eof = options.inaccurate_eof };
        const used = try parseChunk(&p, offset, &file) orelse break;
        try files.append(p.a, file);
        offset += used;
    }
    return .{ .arena = arena, .files = files.items };
}

fn linelen(buf: []const u8) usize {
    if (std.mem.findScalar(u8, buf, '\n')) |i| return i + 1;
    return buf.len;
}

fn startsWith(buf: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, buf, prefix);
}

fn isSpace(c: u8) bool {
    // git's isspace: space, tab, newline, vertical tab, form feed, carriage
    // return
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isDevNull(s: []const u8) bool {
    return startsWith(s, "/dev/null") and s.len > 9 and isSpace(s[9]);
}

const term_space = 1;
const term_tab = 2;

fn nameTerminate(c: u8, terminate: u2) bool {
    if (c == ' ' and terminate & term_space == 0) return false;
    if (c == '\t' and terminate & term_tab == 0) return false;
    return true;
}

/// Runs of slashes made one, which is what lets `--index` find the name.
fn squashSlash(a: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.find(u8, name, "//") == null) return name;
    var out = try a.alloc(u8, name.len);
    var j: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        out[j] = name[i];
        j += 1;
        if (name[i] == '/') {
            i += 1;
            while (i < name.len and name[i] == '/') i += 1;
        } else i += 1;
    }
    return out[0..j];
}

fn withRoot(p: *Parser, name: []const u8) Allocator.Error![]const u8 {
    if (p.options.root.len == 0) return squashSlash(p.a, name);
    return squashSlash(p.a, try std.mem.concat(p.a, u8, &.{ p.options.root, name }));
}

/// A name quoted as git quotes one, with `p_value` components removed.
fn findNameGnu(p: *Parser, line: []const u8, p_value: usize) Allocator.Error!?[]const u8 {
    const got = (try cquote.unquote(p.a, line)) orelse return null;
    var cp: []const u8 = got.name;
    var n = p_value;
    while (n > 0) : (n -= 1) {
        const slash = std.mem.findScalar(u8, cp, '/') orelse return null;
        cp = cp[slash + 1 ..];
    }
    const name = try withRoot(p, cp);
    return name;
}

fn saneTzLen(line: []const u8) usize {
    const n = " +0500".len;
    if (line.len < n or line[line.len - n] != ' ') return 0;
    const tz = line[line.len - n ..];
    if (tz[1] != '+' and tz[1] != '-') return 0;
    for (tz[2..]) |c| if (!isDigit(c)) return 0;
    return n;
}

fn tzWithColonLen(line: []const u8) usize {
    const n = " +08:00".len;
    if (line.len < n or line[line.len - ":00".len] != ':') return 0;
    const tz = line[line.len - n ..];
    if (tz[0] != ' ' or (tz[1] != '+' and tz[1] != '-')) return 0;
    if (!isDigit(tz[2]) or !isDigit(tz[3]) or tz[4] != ':' or !isDigit(tz[5]) or !isDigit(tz[6])) return 0;
    return n;
}

fn dateLen(line: []const u8) usize {
    const n = "72-02-05".len;
    if (line.len < n or line[line.len - "-05".len] != '-') return 0;
    var start = line.len - n;
    const d = line[start..];
    if (!isDigit(d[0]) or !isDigit(d[1]) or d[2] != '-' or !isDigit(d[3]) or !isDigit(d[4]) or d[5] != '-' or
        !isDigit(d[6]) or !isDigit(d[7])) return 0;
    if (start >= 2 and isDigit(line[start - 1]) and isDigit(line[start - 2])) start -= 2;
    return line.len - start;
}

fn shortTimeLen(line: []const u8) usize {
    const n = " 07:01:32".len;
    if (line.len < n or line[line.len - ":32".len] != ':') return 0;
    const t = line[line.len - n ..];
    if (t[0] != ' ' or !isDigit(t[1]) or !isDigit(t[2]) or t[3] != ':' or !isDigit(t[4]) or !isDigit(t[5]) or
        t[6] != ':' or !isDigit(t[7]) or !isDigit(t[8])) return 0;
    return n;
}

fn fractionalTimeLen(line: []const u8) usize {
    if (line.len == 0 or !isDigit(line[line.len - 1])) return 0;
    var at = line.len - 1;
    while (at > 0 and isDigit(line[at])) at -= 1;
    if (line[at] != '.') return 0;
    const n = shortTimeLen(line[0..at]);
    if (n == 0) return 0;
    return line.len - at + n;
}

fn trailingSpacesLen(line: []const u8) usize {
    if (line.len == 0 or line[line.len - 1] != ' ') return 0;
    var at = line.len;
    while (at > 0) {
        at -= 1;
        if (line[at] != ' ') return line.len - (at + 1);
    }
    return line.len;
}

/// How long the timestamp at the end of a `---`/`+++` line is, POSIX or
/// GNU, with the tab or the spaces before it; zero when there is none.
fn diffTimestampLen(line: []const u8) usize {
    if (line.len == 0 or !isDigit(line[line.len - 1])) return 0;
    var end = line.len;
    var n = saneTzLen(line[0..end]);
    if (n == 0) n = tzWithColonLen(line[0..end]);
    end -= n;
    n = shortTimeLen(line[0..end]);
    if (n == 0) n = fractionalTimeLen(line[0..end]);
    end -= n;
    n = dateLen(line[0..end]);
    if (n == 0) return 0;
    end -= n;
    if (end == 0) return 0;
    if (line[end - 1] == '\t') return line.len - (end - 1);
    if (line[end - 1] != ' ') return 0;
    end -= trailingSpacesLen(line[0..end]);
    return line.len - end;
}

/// git's `find_name_common`. `line` runs to the end of the patch; `end`,
/// when given, is where the name must stop.
fn findNameCommon(p: *Parser, line: []const u8, def: ?[]const u8, p_value: usize, end: ?usize, terminate: u2) Allocator.Error!?[]const u8 {
    var start: ?usize = if (p_value == 0) 0 else null;
    var pv = p_value;
    var i: usize = 0;
    const limit = end orelse line.len;
    while (i < limit) {
        const c = line[i];
        if (end == null and isSpace(c)) {
            if (c == '\n') break;
            if (nameTerminate(c, terminate)) break;
        }
        i += 1;
        if (c == '/') {
            if (pv > 0) {
                pv -= 1;
                if (pv == 0) start = i;
            }
        }
    }
    const s = start orelse return if (def) |d| try squashSlash(p.a, d) else null;
    const len = i - s;
    if (len == 0) return if (def) |d| try squashSlash(p.a, d) else null;
    if (def) |d| {
        if (d.len < len and std.mem.startsWith(u8, line[s..], d)) {
            const name = try squashSlash(p.a, d);
            return name;
        }
    }
    const name = try withRoot(p, line[s..i]);
    return name;
}

fn findName(p: *Parser, line: []const u8, def: ?[]const u8, p_value: usize, terminate: u2) Allocator.Error!?[]const u8 {
    if (line.len > 0 and line[0] == '"') {
        if (try findNameGnu(p, line, p_value)) |n| return n;
    }
    return findNameCommon(p, line, def, p_value, null, terminate);
}

fn findNameTraditional(p: *Parser, line: []const u8, def: ?[]const u8, p_value: usize) Allocator.Error!?[]const u8 {
    if (line.len > 0 and line[0] == '"') {
        if (try findNameGnu(p, line, p_value)) |n| return n;
    }
    const len = std.mem.findScalar(u8, line, '\n') orelse line.len;
    const date_len = diffTimestampLen(line[0..len]);
    if (date_len == 0) return findNameCommon(p, line, def, p_value, null, term_tab);
    return findNameCommon(p, line, def, p_value, len - date_len, 0);
}

fn guessPValue(p: *Parser, nameline: []const u8) Allocator.Error!?usize {
    if (isDevNull(nameline)) return null;
    const name = (try findNameTraditional(p, nameline, null, 0)) orelse return null;
    // no prefix is given to the parser, so a name with a slash is not
    // guessed and one without is at depth zero
    if (std.mem.findScalar(u8, name, '/') == null) return 0;
    return null;
}

/// Whether a `---`/`+++` line carries GNU diff's epoch timestamp, which is
/// how it says the file was created or deleted.
fn hasEpochTimestamp(nameline: []const u8) bool {
    const eol = std.mem.findScalar(u8, nameline, '\n') orelse nameline.len;
    const line = nameline[0..eol];
    const tab = std.mem.findScalarLast(u8, line, '\t') orelse return false;
    var ts = line[tab + 1 ..];
    var epoch_hour: i32 = undefined;
    if (startsWith(ts, "1969-12-31 ")) {
        epoch_hour = 24;
        ts = ts["1969-12-31 ".len..];
    } else if (startsWith(ts, "1970-01-01 ")) {
        epoch_hour = 0;
        ts = ts["1970-01-01 ".len..];
    } else return false;
    // ^[0-2][0-9]:([0-5][0-9]):00(\.0+)? ([-+][0-2][0-9]:?[0-5][0-9])$
    if (ts.len < 8) return false;
    if (ts[0] < '0' or ts[0] > '2' or !isDigit(ts[1]) or ts[2] != ':') return false;
    if (ts[3] < '0' or ts[3] > '5' or !isDigit(ts[4]) or ts[5] != ':' or ts[6] != '0' or ts[7] != '0') return false;
    const hour: i32 = (ts[0] - '0') * 10 + (ts[1] - '0');
    const minute: i32 = (ts[3] - '0') * 10 + (ts[4] - '0');
    var at: usize = 8;
    if (at < ts.len and ts[at] == '.') {
        at += 1;
        const zeros = at;
        while (at < ts.len and ts[at] == '0') at += 1;
        if (at == zeros) return false;
    }
    if (at >= ts.len or ts[at] != ' ') return false;
    at += 1;
    const zone = ts[at..];
    if (zone.len < 5) return false;
    if (zone[0] != '+' and zone[0] != '-') return false;
    if (zone[1] < '0' or zone[1] > '2' or !isDigit(zone[2])) return false;
    var z: usize = 3;
    var colon = false;
    if (zone[z] == ':') {
        colon = true;
        z += 1;
    }
    if (z + 2 != zone.len) return false;
    if (zone[z] < '0' or zone[z] > '5' or !isDigit(zone[z + 1])) return false;
    const hh: i32 = (zone[1] - '0') * 10 + (zone[2] - '0');
    const mm: i32 = (zone[z] - '0') * 10 + (zone[z + 1] - '0');
    var offset: i32 = if (colon) hh * 60 + mm else blk: {
        const v = hh * 100 + mm;
        break :blk @divTrunc(v, 100) * 60 + @rem(v, 100);
    };
    if (zone[0] == '-') offset = -offset;
    return hour * 60 + minute - offset == epoch_hour * 60;
}

fn parseTraditional(p: *Parser, first_line: []const u8, second_line: []const u8, file: *FilePatch, line: usize) Error!void {
    const first = first_line[4..];
    const second = second_line[4..];
    if (!p.p_value_known) {
        var a = try guessPValue(p, first);
        const b = try guessPValue(p, second);
        if (a == null) a = b;
        if (a != null and b != null and a.? == b.?) {
            p.p_value = a.?;
            p.p_value_known = true;
        }
    }
    var name: ?[]const u8 = null;
    if (isDevNull(first)) {
        file.is_new = .yes;
        file.is_delete = .no;
        name = try findNameTraditional(p, second, null, p.p_value);
        file.new_name = name;
    } else if (isDevNull(second)) {
        file.is_new = .no;
        file.is_delete = .yes;
        name = try findNameTraditional(p, first, null, p.p_value);
        file.old_name = name;
    } else {
        const first_name = try findNameTraditional(p, first, null, p.p_value);
        name = try findNameTraditional(p, second, first_name, p.p_value);
        if (hasEpochTimestamp(first)) {
            file.is_new = .yes;
            file.is_delete = .no;
            file.new_name = name;
        } else if (hasEpochTimestamp(second)) {
            file.is_new = .no;
            file.is_delete = .yes;
            file.old_name = name;
        } else {
            file.old_name = name;
            file.new_name = name;
        }
    }
    if (name == null) return p.fail(error.MissingFileName, line);
}

/// Remove `p_value` leading components; `null` for an absolute path or too
/// few components.
fn skipTreePrefix(p_value: usize, line: []const u8) ?[]const u8 {
    if (p_value == 0) return if (line.len > 0 and line[0] == '/') null else line;
    var nslash = p_value;
    for (line, 0..) |ch, i| {
        if (ch == '/') {
            nslash -= 1;
            if (nslash == 0) return if (i == 0) null else line[i + 1 ..];
        }
    }
    return null;
}

/// The name on a `diff --git` line when both sides name the same file,
/// which is all a mode change or the creation or deletion of an empty file
/// has to go on.
fn gitHeaderName(p: *Parser, full_line: []const u8) Allocator.Error!?[]const u8 {
    // the line without "diff --git ", its newline kept as git's C string has it
    const line = full_line["diff --git ".len..];
    if (line.len > 0 and line[0] == '"') {
        const first = (try cquote.unquote(p.a, line)) orelse return null;
        const first_name = skipTreePrefix(p.p_value, first.name) orelse return null;
        var second = first.consumed;
        while (second < line.len and isSpace(line[second])) second += 1;
        if (second >= line.len) return null;
        if (line[second] == '"') {
            const sp = (try cquote.unquote(p.a, line[second..])) orelse return null;
            const cp = skipTreePrefix(p.p_value, sp.name) orelse return null;
            if (!std.mem.eql(u8, cp, first_name)) return null;
            return first_name;
        }
        // git compares the rest of the line, its newline included, so a
        // quoted first name and a bare second never agree
        const cp = skipTreePrefix(p.p_value, line[second..]) orelse return null;
        if (!std.mem.eql(u8, cp, first_name)) return null;
        return first_name;
    }
    const name = skipTreePrefix(p.p_value, line) orelse return null;
    // a quote in an unquoted first name begins the second name
    if (std.mem.findScalar(u8, name, '"')) |q| {
        const sp = (try cquote.unquote(p.a, name[q..])) orelse return null;
        const np = skipTreePrefix(p.p_value, sp.name) orelse return null;
        if (np.len < q and std.mem.startsWith(u8, name, np) and isSpace(name[np.len])) return np;
        return null;
    }
    const eol = std.mem.findScalar(u8, name, '\n') orelse return null;
    const line_len = eol;
    var len: usize = 0;
    while (true) : (len += 1) {
        if (len >= name.len) return null;
        switch (name[len]) {
            '\n' => return null,
            '\t', ' ' => {
                if (len + 1 >= name.len) return null;
                const second = skipTreePrefix(p.p_value, name[len + 1 .. line_len]) orelse continue;
                if (second.len == len and std.mem.eql(u8, second, name[0..len])) return name[0..len];
            },
            else => {},
        }
    }
}

fn parseModeLine(p: *Parser, rest: []const u8, line: usize) Error!Mode {
    var i: usize = 0;
    var mode: u32 = 0;
    while (i < rest.len and rest[i] >= '0' and rest[i] <= '7') : (i += 1) {
        mode = mode *% 8 +% (rest[i] - '0');
    }
    if (i == 0 or i >= rest.len or !isSpace(rest[i])) return p.fail(error.InvalidMode, line);
    return canonMode(mode);
}

const HeaderLine = enum {
    hdrend,
    oldname,
    newname,
    oldmode,
    newmode,
    delete,
    newfile,
    copysrc,
    copydst,
    renamesrc,
    renamedst,
    similarity,
    dissimilarity,
    index,
    unrecognized,
};

const optable = [_]struct { str: []const u8, kind: HeaderLine }{
    .{ .str = "@@ -", .kind = .hdrend },
    .{ .str = "--- ", .kind = .oldname },
    .{ .str = "+++ ", .kind = .newname },
    .{ .str = "old mode ", .kind = .oldmode },
    .{ .str = "new mode ", .kind = .newmode },
    .{ .str = "deleted file mode ", .kind = .delete },
    .{ .str = "new file mode ", .kind = .newfile },
    .{ .str = "copy from ", .kind = .copysrc },
    .{ .str = "copy to ", .kind = .copydst },
    .{ .str = "rename old ", .kind = .renamesrc },
    .{ .str = "rename new ", .kind = .renamedst },
    .{ .str = "rename from ", .kind = .renamesrc },
    .{ .str = "rename to ", .kind = .renamedst },
    .{ .str = "similarity index ", .kind = .similarity },
    .{ .str = "dissimilarity index ", .kind = .dissimilarity },
    .{ .str = "index ", .kind = .index },
    .{ .str = "", .kind = .unrecognized },
};

fn strtoulPercent(s: []const u8) ?u8 {
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    var v: u64 = 0;
    const start = i;
    while (i < s.len and isDigit(s[i])) : (i += 1) {
        v = v *| 10 +| (s[i] - '0');
    }
    if (i == start) return 0;
    if (v <= 100) return @intCast(v);
    return null;
}

/// The extended header after `diff --git`. Returns how many bytes it took,
/// the `diff --git` line included.
fn parseGitHeader(p: *Parser, at: usize, first_len: usize, file: *FilePatch) Error!usize {
    file.is_new = .no;
    file.is_delete = .no;
    const header_line = p.linenr;
    var def_name = try gitHeaderName(p, p.text[at .. at + first_len]);
    if (def_name) |d| {
        if (p.options.root.len > 0) def_name = try std.mem.concat(p.a, u8, &.{ p.options.root, d });
    }
    var offset = first_len;
    p.linenr += 1;
    var extension_line: usize = 0;
    outer: while (at + offset < p.text.len) {
        const rest = p.text[at + offset ..];
        const len = linelen(rest);
        if (len == 0 or rest[len - 1] != '\n') break;
        const line = rest[0..len];
        for (optable) |op| {
            if (!startsWith(line, op.str)) continue;
            const value = line[op.str.len..];
            var done = false;
            switch (op.kind) {
                .hdrend, .unrecognized => done = true,
                .oldname => try verifyName(p, value, file.is_new == .yes, &file.old_name, .old),
                .newname => try verifyName(p, value, file.is_delete == .yes, &file.new_name, .new),
                .oldmode => file.old_mode = try parseModeLine(p, value, p.linenr),
                .newmode => file.new_mode = try parseModeLine(p, value, p.linenr),
                .delete => {
                    file.is_delete = .yes;
                    file.old_name = def_name;
                    file.old_mode = try parseModeLine(p, value, p.linenr);
                },
                .newfile => {
                    file.is_new = .yes;
                    file.new_name = def_name;
                    file.new_mode = try parseModeLine(p, value, p.linenr);
                },
                .copysrc => {
                    file.is_copy = true;
                    file.old_name = try findName(p, value, null, p.p_value -| 1, 0);
                },
                .copydst => {
                    file.is_copy = true;
                    file.new_name = try findName(p, value, null, p.p_value -| 1, 0);
                },
                .renamesrc => {
                    file.is_rename = true;
                    file.old_name = try findName(p, value, null, p.p_value -| 1, 0);
                },
                .renamedst => {
                    file.is_rename = true;
                    file.new_name = try findName(p, value, null, p.p_value -| 1, 0);
                },
                .similarity, .dissimilarity => {
                    if (strtoulPercent(value)) |v| file.score = v;
                },
                .index => try parseIndexLine(p, value, file),
            }
            const extensions = @as(u8, @intFromBool(file.is_delete == .yes)) + @intFromBool(file.is_new == .yes) +
                @intFromBool(file.is_rename) + @intFromBool(file.is_copy);
            if (extensions > 1) return p.fail(error.InconsistentHeader, p.linenr);
            if (extensions > 0 and extension_line == 0) extension_line = p.linenr;
            if (done) break :outer;
            break;
        }
        offset += len;
        p.linenr += 1;
    }
    if (file.old_name == null and file.new_name == null) {
        const d = def_name orelse return p.fail(error.MissingFileName, p.linenr);
        file.old_name = d;
        file.new_name = d;
    }
    if ((file.new_name == null and file.is_delete != .yes) or (file.old_name == null and file.is_new != .yes)) {
        return p.fail(error.MissingFileName, p.linenr);
    }
    file.toplevel_relative = true;
    file.line = header_line;
    return offset;
}

const Side = enum { old, new };

fn verifyName(p: *Parser, line: []const u8, isnull: bool, name: *?[]const u8, side: Side) Error!void {
    _ = side;
    if (name.* == null and !isnull) {
        name.* = try findName(p, line, null, p.p_value, term_tab);
        return;
    }
    if (name.*) |existing| {
        if (isnull) return p.fail(error.InconsistentFileName, p.linenr);
        const another = try findName(p, line, null, p.p_value, term_tab);
        if (another == null or !std.mem.eql(u8, another.?, existing)) return p.fail(error.InconsistentFileName, p.linenr);
    } else {
        if (!isDevNull(line)) return p.fail(error.InconsistentFileName, p.linenr);
    }
}

const max_hex = 64;

fn parseIndexLine(p: *Parser, line: []const u8, file: *FilePatch) Error!void {
    const dot = std.mem.findScalar(u8, line, '.') orelse return;
    if (dot + 1 >= line.len or line[dot + 1] != '.' or dot > max_hex) return;
    const old = line[0..dot];
    const rest = line[dot + 2 ..];
    const eol = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
    var end = std.mem.findScalar(u8, rest, ' ') orelse eol;
    if (end > eol) end = eol;
    if (end > max_hex) return;
    file.old_oid_prefix = old;
    file.new_oid_prefix = rest[0..end];
    if (end < rest.len and rest[end] == ' ') file.old_mode = try parseModeLine(p, rest[end + 1 ..], p.linenr);
}

fn parseNum(line: []const u8, out: *usize) usize {
    if (line.len == 0 or !isDigit(line[0])) return 0;
    var i: usize = 0;
    var v: usize = 0;
    while (i < line.len and isDigit(line[i])) : (i += 1) {
        v = std.math.mul(usize, v, 10) catch return 0;
        v = std.math.add(usize, v, line[i] - '0') catch return 0;
    }
    out.* = v;
    return i;
}

/// One `@@` hunk, read by parallax's git grammar: its counts bound the
/// lines, `\ No newline` is the one line after a line, and a hunk that
/// changes nothing is no hunk. Returns how many bytes it took, or `null`
/// when it is none, with the line it is refused at in `p.linenr`.
fn parseFragment(p: *Parser, at: usize, file: *FilePatch, frag: *Fragment) Error!?usize {
    const text = p.text[at..];
    var diagnostics: hunks.Diagnostics = .{};
    const scanned = hunks.scanHunk(text, .{ .dialect = .git, .recount = p.options.recount, .diagnostics = &diagnostics }) catch |err| switch (err) {
        error.InvalidHunkHeader, error.HunkLengthMismatch, error.UnexpectedLine, error.HunkWithoutChange => {
            p.linenr = frag.line + diagnostics.line - 1;
            return null;
        },
    };
    // A number git keeps in an `unsigned long`: past what this machine's
    // holds, a header is corrupt there too.
    frag.old_pos = std.math.cast(usize, scanned.header.old_start) orelse return null;
    frag.old_lines = std.math.cast(usize, scanned.header.old_len) orelse return null;
    frag.new_pos = std.math.cast(usize, scanned.header.new_start) orelse return null;
    frag.new_lines = std.math.cast(usize, scanned.header.new_len) orelse return null;
    frag.leading = std.math.cast(usize, scanned.leading) orelse return null;
    frag.trailing = std.math.cast(usize, scanned.trailing) orelse return null;
    const added = std.math.cast(usize, scanned.added) orelse return null;
    const deleted = std.math.cast(usize, scanned.removed) orelse return null;
    p.linenr = frag.line + (std.math.cast(usize, scanned.lines) orelse return null);
    // Every line the header counts was read, so the context on either side
    // is old lines the hunk keeps: `apply` reduces the context by these.
    assert(deleted <= frag.old_lines);
    assert(frag.leading <= frag.old_lines - deleted);
    assert(frag.trailing <= frag.old_lines - deleted);
    // The old file's line endings are compared as they are when a line it has ends in CR LF.
    if (scanned.crlf.context or (if (p.options.reverse) scanned.crlf.added else scanned.crlf.removed)) file.crlf_in_old = true;
    file.lines_added += added;
    file.lines_deleted += deleted;
    return scanned.consumed;
}

fn parseSinglePatch(p: *Parser, at_in: usize, file: *FilePatch) Error!usize {
    var at = at_in;
    var old_lines: usize = 0;
    var new_lines: usize = 0;
    var context: usize = 0;
    var frags: std.ArrayList(Fragment) = .empty;
    while (p.text.len - at > 4 and startsWith(p.text[at..], "@@ -")) {
        var frag: Fragment = undefined;
        frag.line = p.linenr;
        const len = (try parseFragment(p, at, file, &frag)) orelse return p.fail(error.CorruptPatch, p.linenr);
        if (len == 0) return p.fail(error.CorruptPatch, p.linenr);
        frag.text = p.text[at .. at + len];
        old_lines += frag.old_lines;
        new_lines += frag.new_lines;
        context += frag.leading + frag.trailing;
        try frags.append(p.a, frag);
        at += len;
    }
    file.fragments = frags.items;
    if (file.is_new == .unknown and (old_lines != 0 or frags.items.len > 1)) file.is_new = .no;
    if (file.is_delete == .unknown and (new_lines != 0 or frags.items.len > 1)) file.is_delete = .no;
    if (file.is_new == .yes and old_lines != 0) return p.fail(error.NewFileDependsOnOldContents, p.linenr);
    if (file.is_delete == .yes and new_lines != 0) return p.fail(error.DeletedFileStillHasContents, p.linenr);
    return at - at_in;
}

/// Where the next file header is, and how long it is; `null` when there is
/// none.
fn findHeader(p: *Parser, start: usize, file: *FilePatch) Error!?struct { offset: usize, hdrsize: usize } {
    file.toplevel_relative = false;
    file.is_rename = false;
    file.is_copy = false;
    file.is_new = .unknown;
    file.is_delete = .unknown;
    file.old_mode = 0;
    file.new_mode = 0;
    file.old_name = null;
    file.new_name = null;
    var offset: usize = 0;
    var len: usize = 0;
    while (start + offset < p.text.len) : ({
        offset += len;
        p.linenr += 1;
    }) {
        const rest = p.text[start + offset ..];
        const size = rest.len;
        len = linelen(rest);
        if (len == 0) break;
        if (len < 6) continue;
        if (startsWith(rest, "@@ -")) {
            if (rest[len - 1] != '\n' or hunks.parseHunkHeader(rest[0..len], .git) == null) continue;
            return p.fail(error.FragmentWithoutHeader, p.linenr);
        }
        if (size < len + 6) break;
        if (startsWith(rest, "diff --git ")) {
            const hdr = try parseGitHeader(p, start + offset, len, file);
            if (hdr <= len) continue;
            return .{ .offset = offset, .hdrsize = hdr };
        }
        if (!startsWith(rest, "--- ") or !startsWith(rest[len..], "+++ ")) continue;
        const nextlen = linelen(rest[len..]);
        if (size < nextlen + 14 or !startsWith(rest[len + nextlen ..], "@@ -")) continue;
        file.line = p.linenr;
        try parseTraditional(p, rest[0..len], rest[len .. len + nextlen], file, p.linenr);
        p.linenr += 2;
        return .{ .offset = offset, .hdrsize = len + nextlen };
    }
    return null;
}

/// One file's patch. Returns how many bytes it took, or `null` when no
/// header is left.
fn parseChunk(p: *Parser, at: usize, file: *FilePatch) Error!?usize {
    const found = (try findHeader(p, at, file)) orelse return null;
    const offset = found.offset;
    const hdrsize = found.hdrsize;
    const body = at + offset + hdrsize;
    var patchsize = try parseSinglePatch(p, body, file);
    if (patchsize == 0) {
        const rest = p.text[body..];
        const llen = linelen(rest);
        const git_binary = "GIT binary patch\n";
        if (llen == git_binary.len and startsWith(rest, git_binary)) {
            p.linenr += 1;
            const used = try parseBinary(p, body + llen, file);
            patchsize = if (used != 0) used + llen else 0;
        } else if (llen >= 8 and std.mem.eql(u8, rest[llen - 8 .. llen], " differ\n")) {
            for ([_][]const u8{ "Binary files ", "Files " }) |binhdr| {
                if (binhdr.len < rest.len and startsWith(rest, binhdr)) {
                    p.linenr += 1;
                    file.is_binary = true;
                    patchsize = llen;
                    break;
                }
            }
        }
        if (!file.is_binary and !file.metadataChanges()) return p.fail(error.OnlyGarbage, p.linenr);
    }
    return offset + hdrsize + patchsize;
}

fn parseBinaryHunk(p: *Parser, at: *usize) Error!?BinaryHunk {
    const rest = p.text[at.*..];
    const llen = linelen(rest);
    var method: binarypatch.Method = undefined;
    var orig: []const u8 = undefined;
    if (startsWith(rest, "delta ")) {
        method = .delta;
        orig = rest["delta ".len..llen];
    } else if (startsWith(rest, "literal ")) {
        method = .literal;
        orig = rest["literal ".len..llen];
    } else return null;
    var origlen: usize = 0;
    {
        var i: usize = 0;
        while (i < orig.len and isSpace(orig[i]) and orig[i] != '\n') i += 1;
        _ = parseNum(orig[i..], &origlen);
    }
    p.linenr += 1;
    var pos = at.* + llen;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(p.a);
    while (true) {
        if (pos >= p.text.len) return p.fail(error.CorruptBinaryPatch, p.linenr);
        const line = p.text[pos..];
        const len = linelen(line);
        p.linenr += 1;
        if (len == 1) {
            pos += 1;
            break;
        }
        if (len < 7 or (len - 2) % 5 != 0) return p.fail(error.CorruptBinaryPatch, p.linenr - 1);
        const max_byte_length = (len - 2) / 5 * 4;
        const byte_length: usize = switch (line[0]) {
            'A'...'Z' => line[0] - 'A' + 1,
            'a'...'z' => line[0] - 'a' + 27,
            else => return p.fail(error.CorruptBinaryPatch, p.linenr - 1),
        };
        if (max_byte_length < byte_length or byte_length + 4 <= max_byte_length) return p.fail(error.CorruptBinaryPatch, p.linenr - 1);
        const start = data.items.len;
        try data.resize(p.a, start + byte_length);
        binarypatch.decode85(data.items[start..], line[1 .. len - 1]) catch return p.fail(error.CorruptBinaryPatch, p.linenr - 1);
        pos += len;
    }
    const inflated = binarypatch.inflate(p.a, data.items, origlen) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return p.fail(error.CorruptBinaryPatch, p.linenr - 1),
    };
    at.* = pos;
    return .{ .method = method, .data = inflated };
}

fn parseBinary(p: *Parser, at_in: usize, file: *FilePatch) Error!usize {
    var at = at_in;
    const forward = (try parseBinaryHunk(p, &at)) orelse return p.fail(error.UnrecognizedBinaryPatch, p.linenr - 1);
    const reverse = try parseBinaryHunk(p, &at);
    file.binary = .{ .forward = forward, .reverse = reverse };
    file.is_binary = true;
    return at - at_in;
}

test "a git patch reads as its files, names, modes and hunks" {
    const gpa = std.testing.allocator;
    const text =
        \\From abc Mon Sep 17 00:00:00 2001
        \\Subject: [PATCH] change
        \\
        \\---
        \\ a.txt | 2 +-
        \\
        \\diff --git a/a.txt b/a.txt
        \\index 1111111..2222222 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,3 +1,3 @@
        \\ one
        \\-two
        \\+TWO
        \\ three
        \\diff --git a/old b/new
        \\similarity index 90%
        \\rename from old
        \\rename to new
        \\diff --git a/x.sh b/x.sh
        \\old mode 100644
        \\new mode 100755
        \\--
        \\2.40.0
        \\
    ;
    var patch = try parse(gpa, text, .{});
    defer patch.deinit();
    try std.testing.expectEqual(@as(usize, 3), patch.files.len);
    const first = patch.files[0];
    try std.testing.expectEqualStrings("a.txt", first.old_name.?);
    try std.testing.expectEqualStrings("a.txt", first.new_name.?);
    try std.testing.expectEqual(mode_file, first.old_mode);
    try std.testing.expectEqualStrings("1111111", first.old_oid_prefix);
    try std.testing.expectEqual(@as(usize, 1), first.fragments.len);
    try std.testing.expectEqual(@as(usize, 1), first.fragments[0].leading);
    try std.testing.expectEqual(@as(usize, 1), first.fragments[0].trailing);
    try std.testing.expectEqual(@as(usize, 1), first.lines_added);
    const second = patch.files[1];
    try std.testing.expect(second.is_rename);
    try std.testing.expectEqual(@as(u8, 90), second.score);
    try std.testing.expectEqualStrings("old", second.old_name.?);
    try std.testing.expectEqualStrings("new", second.new_name.?);
    const third = patch.files[2];
    try std.testing.expectEqual(mode_exec, third.new_mode);
    try std.testing.expectEqualStrings("x.sh", third.new_name.?);
}

test "a traditional patch guesses its strip count and reads GNU timestamps" {
    const gpa = std.testing.allocator;
    const text = "--- file.c\t2010-07-05 19:41:17.620000023 -0500\n" ++
        "+++ file.c\t2010-07-05 19:41:17.620000023 -0500\n" ++
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\--- /dev/null
        \\+++ dir/new.c
        \\@@ -0,0 +1 @@
        \\+x
        \\
    ;
    var patch = try parse(gpa, text, .{});
    defer patch.deinit();
    try std.testing.expectEqual(@as(usize, 2), patch.files.len);
    try std.testing.expectEqualStrings("file.c", patch.files[0].new_name.?);
    try std.testing.expectEqualStrings("dir/new.c", patch.files[1].new_name.?);
    try std.testing.expect(patch.files[1].is_new == .yes);
}

test "a hunk whose counts do not add up is a corrupt patch, at its line" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    const text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-a\n+b\n";
    try std.testing.expectError(error.CorruptPatch, parse(gpa, text, .{ .diagnostic = &diag }));
    try std.testing.expect(diag.line != 0);
    try std.testing.expectError(error.FragmentWithoutHeader, parse(gpa, "@@ -1 +1 @@\n-a\n+b\n", .{}));
}

test "a quoted name in a git header is unquoted" {
    const gpa = std.testing.allocator;
    const text = "diff --git \"a/sp ace\\tx\" \"b/sp ace\\tx\"\nnew file mode 100644\nindex 0000000..e69de29\n";
    var patch = try parse(gpa, text, .{});
    defer patch.deinit();
    try std.testing.expectEqualStrings("sp ace\tx", patch.files[0].new_name.?);
    try std.testing.expect(patch.files[0].is_new == .yes);
}

test "fuzz: any bytes are a patch or a named refusal" {
    try shakedown.check(std.testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var buf: [2048]u8 = undefined;
            const len = shakedown.gen.intRange(case.source, usize, 0, buf.len);
            case.source.bytes(buf[0..len]);
            var patch = parse(std.testing.allocator, buf[0..len], .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return,
            };
            defer patch.deinit();
            for (patch.files) |f| {
                for (f.fragments) |frag| try std.testing.expect(frag.text.len > 0);
                try std.testing.expect(f.old_name != null or f.new_name != null);
            }
        }
    }.one, .{});
}
