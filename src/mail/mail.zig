//! Reading patches out of email: `git mailsplit`, which cuts a mailbox into
//! messages, and `git mailinfo`, which takes one message apart into its
//! author, date, subject, commit message and patch.
//!
//! Both are git's own, rule for rule: a message starts at a `From ` line
//! that ends in something that looks like a date; headers fold; RFC 2047
//! encoded words are decoded in headers, quoted-printable and base64 in
//! bodies, and a `format=flowed` body is unflowed; a multipart message's
//! parts are read in order; the subject loses `Re:` and `[PATCH ...]`;
//! in-body `From:`, `Subject:` and `Date:` lines override the mail's; a
//! scissors line throws away what came before it; the patch starts at
//! `---`, `diff -` or `Index: `. Text in UTF-8, US-ASCII or ISO-8859-1 is
//! taken into UTF-8; any other character set is refused by name, where git
//! would convert it with iconv.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors from reading mail.
pub const Error = error{
    /// The mailbox's first message has no `From ` line and bare messages
    /// were not allowed: git's "corrupt mailbox".
    CorruptMailbox,
    /// A message with nothing in it.
    EmptyPatch,
    /// A header or body names a character set this package does not
    /// convert.
    UnsupportedCharset,
    /// Text in a character set holds bytes that set does not have.
    InvalidCharset,
    /// More nested multipart boundaries than git's five.
    TooManyBoundaries,
    /// A multipart message closes a boundary it never opened.
    MismatchedBoundaries,
    /// A NUL byte in the author, subject or date.
    NulInHeader,
    /// An encoded word that does not decode.
    MalformedEncodedWord,
} || Allocator.Error;

//=========================================================================
// mailsplit
//=========================================================================

/// How a mailbox is cut.
pub const SplitOptions = struct {
    /// `--keep-cr`: CR LF line ends are left alone.
    keep_cr: bool = false,
    /// `--mboxrd`: one `>` is taken off `>From ` lines.
    mboxrd: bool = false,
    /// `-b`: the first message may lack its `From ` line.
    allow_bare: bool = true,
};

/// The messages of a mailbox, each as `git mailsplit` writes it to a
/// file. Owned by its arena.
pub const Mailbox = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const []const u8,

    pub fn deinit(m: *Mailbox) void {
        m.arena.deinit();
        m.* = undefined;
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

/// git's `is_from_line`: `From ` and, somewhere before the end, a time
/// with its colons and a year after 1990.
pub fn isFromLine(line: []const u8) bool {
    const len = line.len;
    if (len < 20 or !std.mem.startsWith(u8, line, "From ")) return false;
    var colon: usize = len - 2;
    while (true) {
        if (colon < 5) return false;
        colon -= 1;
        if (line[colon] == ':') break;
    }
    if (colon < 4 or colon + 2 >= len) return false;
    if (!isDigit(line[colon - 4]) or !isDigit(line[colon - 2]) or !isDigit(line[colon - 1]) or
        !isDigit(line[colon + 1]) or !isDigit(line[colon + 2])) return false;
    // the year: strtol from three past the colon
    var i = colon + 3;
    while (i < len and isSpace(line[i])) i += 1;
    var neg = false;
    if (i < len and (line[i] == '-' or line[i] == '+')) {
        neg = line[i] == '-';
        i += 1;
    }
    var year: i64 = 0;
    while (i < len and isDigit(line[i])) : (i += 1) year = year *| 10 +| (line[i] - '0');
    if (neg) year = -year;
    return year > 90;
}

fn isGtFrom(line: []const u8) bool {
    if (line.len < ">From ".len) return false;
    var ngt: usize = 0;
    while (ngt < line.len and line[ngt] == '>') ngt += 1;
    return ngt > 0 and std.mem.startsWith(u8, line[ngt..], "From ");
}

/// Cut `mbox` into its messages: `git mailsplit -b`.
pub fn split(gpa: Allocator, mbox: []const u8, options: SplitOptions) Self.Error!Mailbox {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var messages: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    // leading whitespace before the first message
    while (at < mbox.len and isSpace(mbox[at])) at += 1;
    if (at >= mbox.len) return .{ .arena = arena, .messages = &.{} };
    var line = nextWholeLine(mbox, &at).?;
    var done = false;
    while (!done) {
        const is_bare = !isFromLine(line);
        if (is_bare and !options.allow_bare) return error.CorruptMailbox;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            var piece = line;
            var crlf_fixed = false;
            if (!options.keep_cr and piece.len > 1 and piece[piece.len - 1] == '\n' and piece[piece.len - 2] == '\r') crlf_fixed = true;
            var start: usize = 0;
            if (options.mboxrd and isGtFrom(piece)) start = 1;
            if (crlf_fixed) {
                try out.appendSlice(a, piece[start .. piece.len - 2]);
                try out.append(a, '\n');
            } else try out.appendSlice(a, piece[start..]);
            piece = undefined;
            line = nextWholeLine(mbox, &at) orelse {
                done = true;
                break;
            };
            if (!is_bare and isFromLine(line)) break;
        }
        try messages.append(a, out.items);
    }
    return .{ .arena = arena, .messages = messages.items };
}

fn nextWholeLine(text: []const u8, at: *usize) ?[]const u8 {
    if (at.* >= text.len) return null;
    const start = at.*;
    const end = if (std.mem.findScalarPos(u8, text, start, '\n')) |nl| nl + 1 else text.len;
    at.* = end;
    return text[start..end];
}

//=========================================================================
// mailinfo
//=========================================================================

/// What `git mailinfo -m` does with a quoted CR.
pub const QuotedCr = enum { nowarn, warn, strip };

/// How a message is read.
pub const InfoOptions = struct {
    /// `-k`: the subject as it is.
    keep_subject: bool = false,
    /// `-b`: brackets other than `[PATCH...]` stay in the subject.
    keep_non_patch_brackets: bool = false,
    /// `-m`: the `Message-ID` is added to the message.
    add_message_id: bool = false,
    /// `--scissors`.
    scissors: bool = false,
    /// `--quoted-cr`.
    quoted_cr: QuotedCr = .warn,
    /// `-u`: text is taken into UTF-8. `false` (`-n`) leaves it as sent.
    utf8: bool = true,
    /// `--no-inbody-headers` is `false`.
    inbody_headers: bool = true,
};

/// What a message held.
pub const Info = struct {
    arena: std.heap.ArenaAllocator,
    /// `Author:`, `Email:`, `Subject:` and `Date:`, absent when the mail
    /// had none.
    author: ?[]const u8 = null,
    email: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    date: ?[]const u8 = null,
    /// The commit message's body, as `mailinfo` writes its `msg` file.
    message: []const u8 = "",
    /// The patch, as `mailinfo` writes its `patch` file.
    patch: []const u8 = "",
    /// The `info` file's text: `Author:`, `Email:`, `Subject:` and `Date:`
    /// lines and a blank line.
    info: []const u8 = "",
    /// The body had a CR LF line end in a quoted-printable or base64 part.
    quoted_cr: bool = false,
    /// The body was `format=flowed`, whose trailing spaces are lost.
    format_flowed: bool = false,

    pub fn deinit(i: *Info) void {
        i.arena.deinit();
        i.* = undefined;
    }
};

const max_boundaries = 5;

const TransferEncoding = enum { dontcare, qp, base64 };

const header_names = [_][]const u8{ "From", "Subject", "Date" };

const State = struct {
    a: Allocator,
    options: InfoOptions,
    input: []const u8,
    pos: usize = 0,
    name: std.ArrayList(u8) = .empty,
    email: std.ArrayList(u8) = .empty,
    content: [max_boundaries]?[]const u8 = @splat(null),
    content_top: usize = 0,
    charset: std.ArrayList(u8) = .empty,
    format_flowed: bool = false,
    delsp: bool = false,
    have_quoted_cr: bool = false,
    any_quoted_cr: bool = false,
    message_id: ?[]const u8 = null,
    transfer_encoding: TransferEncoding = .dontcare,
    patch_lines: usize = 0,
    filter_stage: u1 = 0,
    header_stage: bool = true,
    inbody_header_accum: std.ArrayList(u8) = .empty,
    p_hdr: [3]?[]const u8 = @splat(null),
    s_hdr: [3]?[]const u8 = @splat(null),
    log_message: std.ArrayList(u8) = .empty,
    patch: std.ArrayList(u8) = .empty,
    input_error: ?Error = null,

    fn top(s: *const State) ?[]const u8 {
        return s.content[s.content_top];
    }

    /// One line without its newline, as `strbuf_getline_lf` reads it.
    fn getLineLf(s: *State) ?[]const u8 {
        if (s.pos >= s.input.len) return null;
        const start = s.pos;
        if (std.mem.findScalarPos(u8, s.input, start, '\n')) |nl| {
            s.pos = nl + 1;
            return s.input[start..nl];
        }
        s.pos = s.input.len;
        return s.input[start..];
    }

    /// One line with its newline, as `strbuf_getwholeline` reads it.
    fn getWholeLine(s: *State) ?[]const u8 {
        return nextWholeLine(s.input, &s.pos);
    }

    fn peek(s: *const State) ?u8 {
        return if (s.pos < s.input.len) s.input[s.pos] else null;
    }
};

fn rtrim(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and isSpace(s[end - 1])) end -= 1;
    return s[0..end];
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and isSpace(s[start])) start += 1;
    return rtrim(s[start..]);
}

fn cstr(s: []const u8) []const u8 {
    // the C string git's code sees ends at a NUL
    return if (std.mem.findScalar(u8, s, 0)) |z| s[0..z] else s;
}

/// Runs of whitespace made one space.
fn cleanupSpace(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (isSpace(s[i])) {
            try out.append(a, ' ');
            i += 1;
            while (i < s.len and isSpace(s[i])) i += 1;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.items;
}

fn isRfc2822Header(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "From ") or std.mem.startsWith(u8, line, ">From ")) return true;
    for (line) |ch| {
        if (ch == 0) return false;
        if (ch == ':') return true;
        if ((ch >= 33 and ch <= 57) or (ch >= 59 and ch <= 126)) continue;
        return false;
    }
    return false;
}

/// A header line with its folded continuations, or `null` when the next
/// line is not a header; then `rest` is that line with its newline.
fn readOneHeaderLine(s: *State, rest: *?[]const u8) Error!?[]const u8 {
    const first = s.getLineLf() orelse {
        rest.* = null;
        return null;
    };
    const line = rtrim(first);
    if (line.len == 0 or !isRfc2822Header(line)) {
        rest.* = try std.mem.concat(s.a, u8, &.{ line, "\n" });
        return null;
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(s.a, line);
    while (true) {
        const c = s.peek() orelse break;
        if (c != ' ' and c != '\t') break;
        const cont = s.getLineLf() orelse break;
        // the continuation's first byte becomes a space, then the whole
        // is trimmed: one of only whitespace adds nothing
        const piece = try std.mem.concat(s.a, u8, &.{ " ", cont[1..] });
        try out.appendSlice(s.a, rtrim(piece));
    }
    return out.items;
}

fn skipHeader(line: []const u8, hdr: []const u8) ?[]const u8 {
    if (line.len < hdr.len or !std.ascii.eqlIgnoreCase(line[0..hdr.len], hdr)) return null;
    var rest = line[hdr.len..];
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = rest[1..];
    var i: usize = 0;
    while (i < rest.len and isSpace(rest[i])) i += 1;
    return rest[i..];
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn decodeQ(a: Allocator, out: *std.ArrayList(u8), in_raw: []const u8, rfc2047: bool) Allocator.Error!void {
    const in = cstr(in_raw);
    var i: usize = 0;
    while (i < in.len) {
        var c = in[i];
        i += 1;
        if (c == '=') {
            if (i >= in.len or in[i] == '\n') break;
            if (i + 1 < in.len) {
                if (hexVal(in[i])) |hi| {
                    if (hexVal(in[i + 1])) |lo| {
                        try out.append(a, hi << 4 | lo);
                        i += 2;
                        continue;
                    }
                }
            }
        }
        if (rfc2047 and c == '_') c = ' ';
        try out.append(a, c);
    }
}

fn decodeB(a: Allocator, out: *std.ArrayList(u8), in_raw: []const u8) Allocator.Error!void {
    const in = cstr(in_raw);
    var pos: u2 = 0;
    var acc: u8 = 0;
    for (in) |ch| {
        const c: u8 = switch (ch) {
            '+' => 62,
            '/' => 63,
            'A'...'Z' => ch - 'A',
            'a'...'z' => ch - 'a' + 26,
            '0'...'9' => ch - '0' + 52,
            else => continue,
        };
        switch (pos) {
            0 => acc = c << 2,
            1 => {
                try out.append(a, acc | (c >> 4));
                acc = (c & 15) << 4;
            },
            2 => {
                try out.append(a, acc | (c >> 2));
                acc = (c & 3) << 6;
            },
            3 => {
                try out.append(a, acc | c);
                acc = 0;
            },
        }
        pos +%= 1;
    }
}

fn sameUtf(src: []const u8, dst: []const u8) bool {
    if (src.len < 3 or dst.len < 3) return false;
    if (!std.ascii.eqlIgnoreCase(src[0..3], "utf") or !std.ascii.eqlIgnoreCase(dst[0..3], "utf")) return false;
    var s = src[3..];
    var d = dst[3..];
    if (s.len > 0 and s[0] == '-') s = s[1..];
    if (d.len > 0 and d[0] == '-') d = d[1..];
    return std.ascii.eqlIgnoreCase(s, d);
}

/// Take `text` from `charset` into UTF-8.
fn convertToUtf8(s: *State, text: []const u8, charset: []const u8) Error![]const u8 {
    if (!s.options.utf8 or charset.len == 0) return text;
    if (sameUtf("UTF-8", charset) or std.ascii.eqlIgnoreCase("UTF-8", charset)) return text;
    if (std.ascii.eqlIgnoreCase(charset, "us-ascii") or std.ascii.eqlIgnoreCase(charset, "ascii")) {
        for (text) |c| if (c >= 0x80) return error.InvalidCharset;
        return text;
    }
    if (std.ascii.eqlIgnoreCase(charset, "iso-8859-1") or std.ascii.eqlIgnoreCase(charset, "latin1") or
        std.ascii.eqlIgnoreCase(charset, "iso8859-1") or std.ascii.eqlIgnoreCase(charset, "latin-1"))
    {
        var out: std.ArrayList(u8) = .empty;
        for (text) |b| {
            if (b < 0x80) try out.append(s.a, b) else {
                try out.append(s.a, 0xc0 | (b >> 6));
                try out.append(s.a, 0x80 | (b & 0x3f));
            }
        }
        return out.items;
    }
    return error.UnsupportedCharset;
}

/// RFC 2047 encoded words in a header value, decoded.
fn decodeHeader(s: *State, it: []const u8) Error![]const u8 {
    const a = s.a;
    var out: std.ArrayList(u8) = .empty;
    var in: usize = 0;
    while (in <= it.len) {
        const ep_rel = std.mem.find(u8, it[in..], "=?") orelse break;
        var ep = in + ep_rel;
        if (in != ep) {
            var scan = in;
            while (scan < ep and isSpace(it[scan])) scan += 1;
            if (scan != ep or in == 0) try out.appendSlice(a, it[in..ep]);
        }
        ep += 2;
        if (ep >= it.len) return error.MalformedEncodedWord;
        const cp = std.mem.findScalarPos(u8, it, ep, '?') orelse return error.MalformedEncodedWord;
        if (cp + 3 > it.len) return error.MalformedEncodedWord;
        const charset = it[ep..cp];
        const encoding = it[cp + 1];
        if (it[cp + 2] != '?') return error.MalformedEncodedWord;
        const end = std.mem.findPos(u8, it, cp + 3, "?=") orelse return error.MalformedEncodedWord;
        const piece = it[cp + 3 .. end];
        var dec: std.ArrayList(u8) = .empty;
        switch (std.ascii.toLower(encoding)) {
            'b' => try decodeB(a, &dec, piece),
            'q' => try decodeQ(a, &dec, piece, true),
            else => return error.MalformedEncodedWord,
        }
        try out.appendSlice(a, try convertToUtf8(s, dec.items, charset));
        in = end + 2;
    }
    if (in < it.len) try out.appendSlice(a, it[in..]);
    return out.items;
}

fn parseHeader(s: *State, line: []const u8, hdr: []const u8) Error!?[]const u8 {
    const v = skipHeader(line, hdr) orelse return null;
    const decoded = try decodeHeader(s, v);
    return decoded;
}

fn slurpAttr(line: []const u8, name: []const u8) ?[]const u8 {
    const at = std.ascii.findIgnoreCase(line, name) orelse return null;
    var ap = at + name.len;
    var ends: []const u8 = "; \t";
    if (ap < line.len and line[ap] == '"') {
        ap += 1;
        ends = "\"";
    }
    var end = ap;
    while (end < line.len and std.mem.findScalar(u8, ends, line[end]) == null) end += 1;
    return line[ap..end];
}

fn hasAttrValue(line: []const u8, name: []const u8, value: []const u8) bool {
    const v = slurpAttr(line, name) orelse return false;
    return std.ascii.eqlIgnoreCase(v, value);
}

fn handleContentType(s: *State, line: []const u8) Error!void {
    s.format_flowed = hasAttrValue(line, "format=", "flowed");
    s.delsp = hasAttrValue(line, "delsp=", "yes");
    if (slurpAttr(line, "boundary=")) |b| {
        if (s.content_top + 1 >= max_boundaries) {
            s.input_error = error.TooManyBoundaries;
            return;
        }
        s.content_top += 1;
        s.content[s.content_top] = try std.mem.concat(s.a, u8, &.{ "--", b });
    }
    s.charset.clearRetainingCapacity();
    if (slurpAttr(line, "charset=")) |cs| try s.charset.appendSlice(s.a, cs);
}

fn handleContentTransferEncoding(s: *State, line: []const u8) void {
    if (std.ascii.findIgnoreCase(line, "base64") != null) {
        s.transfer_encoding = .base64;
    } else if (std.ascii.findIgnoreCase(line, "quoted-printable") != null) {
        s.transfer_encoding = .qp;
    } else s.transfer_encoding = .dontcare;
}

const HdrSet = enum { primary, secondary };

fn checkHeader(s: *State, line: []const u8, set: HdrSet, overwrite: bool) Error!bool {
    const data = if (set == .primary) &s.p_hdr else &s.s_hdr;
    for (header_names, 0..) |name, i| {
        if (data[i] == null or overwrite) {
            if (try parseHeader(s, line, name)) |v| {
                data[i] = v;
                return true;
            }
        }
    }
    if (try parseHeader(s, line, "Content-Type")) |v| {
        try handleContentType(s, v);
        return true;
    }
    if (try parseHeader(s, line, "Content-Transfer-Encoding")) |v| {
        handleContentTransferEncoding(s, v);
        return true;
    }
    if (try parseHeader(s, line, "Message-ID")) |v| {
        if (s.options.add_message_id) s.message_id = v;
        return true;
    }
    return false;
}

fn isInbodyHeader(s: *const State, line: []const u8) bool {
    for (header_names, 0..) |name, i| {
        if (s.s_hdr[i] == null and skipHeader(line, name) != null) return true;
    }
    return false;
}

fn decodeTransferEncoding(s: *State, line: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    switch (s.transfer_encoding) {
        .qp => try decodeQ(s.a, &out, line, false),
        .base64 => try decodeB(s.a, &out, line),
        .dontcare => return line,
    }
    return out.items;
}

/// git's `patchbreak`: where the commit message ends and the patch starts.
pub fn patchbreak(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "diff -")) return true;
    if (std.mem.startsWith(u8, line, "Index: ")) return true;
    if (line.len < 4) return false;
    if (std.mem.startsWith(u8, line, "---")) {
        // git reads the NUL past a four-byte line, which is no space.
        if (line[3] == ' ' and (line.len == 4 or !isSpace(line[4]))) return true;
        var i: usize = 3;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (c == '\n') return true;
            if (!isSpace(c)) break;
        }
        return false;
    }
    return false;
}

/// git's `is_scissors_line`: a line of dashes with `>8` or `8<` in it.
pub fn isScissorsLine(line_raw: []const u8) bool {
    const line = cstr(line_raw);
    var scissors: usize = 0;
    var gap: usize = 0;
    var first_nonblank: ?usize = null;
    var last_nonblank: ?usize = null;
    var perforation: usize = 0;
    var in_perforation = false;
    var c: usize = 0;
    while (c < line.len) : (c += 1) {
        if (isSpace(line[c])) {
            if (in_perforation) {
                perforation += 1;
                gap += 1;
            }
            continue;
        }
        last_nonblank = c;
        if (first_nonblank == null) first_nonblank = c;
        if (line[c] == '-') {
            in_perforation = true;
            perforation += 1;
            continue;
        }
        const rest = line[c..];
        if (std.mem.startsWith(u8, rest, ">8") or std.mem.startsWith(u8, rest, "8<") or
            std.mem.startsWith(u8, rest, ">%") or std.mem.startsWith(u8, rest, "%<"))
        {
            in_perforation = true;
            perforation += 2;
            scissors += 2;
            c += 1;
            continue;
        }
        in_perforation = false;
    }
    const visible: usize = if (first_nonblank != null and last_nonblank != null) last_nonblank.? - first_nonblank.? + 1 else 0;
    return scissors != 0 and 8 <= visible and visible < perforation * 3 and gap * 2 < perforation;
}

fn isFormatPatchSeparator(line: []const u8) bool {
    const sample = "From e6807f3efca28b30decfecb1732a56c7db1137ee Mon Sep 17 00:00:00 2001\n";
    if (line.len != sample.len) return false;
    if (!std.mem.startsWith(u8, line, "From ")) return false;
    const cp = line[5..];
    var n: usize = 0;
    while (n < cp.len and (isDigit(cp[n]) or (cp[n] >= 'a' and cp[n] <= 'f'))) n += 1;
    if (n != 40) return false;
    return std.mem.eql(u8, line[45..], sample[45..]);
}

fn flushInbodyHeaderAccum(s: *State) Error!void {
    if (s.inbody_header_accum.items.len == 0) return;
    const accum = try s.a.dupe(u8, s.inbody_header_accum.items);
    _ = try checkHeader(s, accum, .secondary, false);
    s.inbody_header_accum.clearRetainingCapacity();
}

fn checkInbodyHeader(s: *State, line: []const u8) Error!bool {
    if (s.inbody_header_accum.items.len != 0 and line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
        if (s.options.scissors and isScissorsLine(line)) {
            try flushInbodyHeaderAccum(s);
            return false;
        }
        if (std.mem.endsWith(u8, s.inbody_header_accum.items, "\n")) _ = s.inbody_header_accum.pop();
        try s.inbody_header_accum.appendSlice(s.a, line);
        return true;
    }
    try flushInbodyHeaderAccum(s);
    if (std.mem.startsWith(u8, line, ">From") and line.len > 5 and isSpace(line[5])) return isFormatPatchSeparator(line[1..]);
    if (std.mem.startsWith(u8, line, "[PATCH]") and line.len > 7 and isSpace(line[7])) {
        s.s_hdr[1] = try s.a.dupe(u8, line);
        return true;
    }
    if (isInbodyHeader(s, line)) {
        try s.inbody_header_accum.appendSlice(s.a, line);
        return true;
    }
    return false;
}

/// Returns whether the line starts the patch.
fn handleCommitMsg(s: *State, line_in: []const u8) Error!bool {
    var line = line_in;
    if (s.header_stage) {
        if (line.len == 0 or (line.len == 1 and line[0] == '\n')) {
            if (s.inbody_header_accum.items.len != 0) {
                try flushInbodyHeaderAccum(s);
                s.header_stage = false;
            }
            return false;
        }
    }
    if (s.options.inbody_headers and s.header_stage) {
        s.header_stage = try checkInbodyHeader(s, line);
        if (s.header_stage) return false;
    } else s.header_stage = false;

    line = try convertToUtf8(s, line, s.charset.items);

    if (s.options.scissors and isScissorsLine(line)) {
        s.log_message.clearRetainingCapacity();
        s.header_stage = true;
        s.s_hdr = @splat(null);
        return false;
    }
    if (patchbreak(line)) {
        if (s.message_id) |id| try s.log_message.print(s.a, "Message-ID: {s}\n", .{id});
        return true;
    }
    try s.log_message.appendSlice(s.a, line);
    return false;
}

fn handleFilter(s: *State, line: []const u8) Error!void {
    if (s.filter_stage == 0) {
        if (!try handleCommitMsg(s, line)) return;
        s.filter_stage = 1;
    }
    try s.patch.appendSlice(s.a, line);
    s.patch_lines += 1;
}

fn handleFilterFlowed(s: *State, line_in: []const u8, prev: *std.ArrayList(u8)) Error!void {
    var line = line_in;
    var len = line.len;
    if (!s.format_flowed) {
        if (len >= 2 and line[len - 2] == '\r' and line[len - 1] == '\n') {
            s.have_quoted_cr = true;
            s.any_quoted_cr = true;
            if (s.options.quoted_cr == .strip) {
                line = try std.mem.concat(s.a, u8, &.{ line[0 .. len - 2], "\n" });
            }
        }
        return handleFilter(s, line);
    }
    if (len > 0 and line[len - 1] == '\n') {
        len -= 1;
        if (len > 0 and line[len - 1] == '\r') len -= 1;
    }
    if (std.mem.startsWith(u8, line, "-- ") and len == 3) {
        if (prev.items.len != 0) {
            try handleFilter(s, try s.a.dupe(u8, prev.items));
            prev.clearRetainingCapacity();
        }
        return handleFilter(s, line);
    }
    if (len > 0 and line[0] == ' ') {
        line = line[1..];
        len -= 1;
    }
    if (len > 0 and line[len - 1] == ' ') {
        try prev.appendSlice(s.a, line[0 .. len - @intFromBool(s.delsp)]);
        return;
    }
    const joined = try std.mem.concat(s.a, u8, &.{ prev.items, line });
    prev.clearRetainingCapacity();
    return handleFilter(s, joined);
}

fn isMultipartBoundary(s: *const State, line: []const u8) bool {
    const b = s.top() orelse return false;
    return b.len <= line.len and std.mem.eql(u8, line[0..b.len], b);
}

fn findBoundary(s: *State) ?[]const u8 {
    while (s.getLineLf()) |line| {
        if (s.top() != null and isMultipartBoundary(s, line)) return line;
    }
    return null;
}

/// Returns the line to go on with, or `null` to stop.
fn handleBoundary(s: *State, line_in: []const u8) Error!?[]const u8 {
    var line = line_in;
    while (true) {
        const b = s.top().?;
        if (line.len >= b.len + 2 and std.mem.eql(u8, line[b.len .. b.len + 2], "--")) {
            s.content[s.content_top] = null;
            if (s.content_top == 0) {
                s.input_error = error.MismatchedBoundaries;
                return null;
            }
            s.content_top -= 1;
            try handleFilter(s, "\n");
            if (s.input_error != null) return null;
            line = findBoundary(s) orelse return null;
            continue;
        }
        break;
    }
    s.transfer_encoding = .dontcare;
    s.charset.clearRetainingCapacity();
    var rest: ?[]const u8 = null;
    while (try readOneHeaderLine(s, &rest)) |h| _ = try checkHeader(s, h, .primary, false);
    const next = s.getLineLf() orelse return null;
    const terminated = try std.mem.concat(s.a, u8, &.{ next, "\n" });
    return terminated;
}

fn handleBody(s: *State, first_line: []const u8) Error!void {
    var prev: std.ArrayList(u8) = .empty;
    var line = first_line;
    if (s.top() != null) {
        line = findBoundary(s) orelse return;
    }
    while (true) {
        if (s.top() != null and isMultipartBoundary(s, line)) {
            if (prev.items.len != 0) {
                try handleFilter(s, try s.a.dupe(u8, prev.items));
                prev.clearRetainingCapacity();
            }
            s.have_quoted_cr = false;
            line = (try handleBoundary(s, line)) orelse return;
        }
        const decoded = try decodeTransferEncoding(s, line);
        switch (s.transfer_encoding) {
            .base64, .qp => {
                const joined = try std.mem.concat(s.a, u8, &.{ prev.items, decoded });
                prev.clearRetainingCapacity();
                var rest = joined;
                while (rest.len > 0) {
                    const nl = std.mem.findScalar(u8, rest, '\n');
                    if (nl == null) {
                        try prev.appendSlice(s.a, rest);
                        break;
                    }
                    try handleFilterFlowed(s, rest[0 .. nl.? + 1], &prev);
                    rest = rest[nl.? + 1 ..];
                }
            },
            .dontcare => try handleFilterFlowed(s, decoded, &prev),
        }
        if (s.input_error != null) break;
        line = s.getWholeLine() orelse break;
    }
    if (prev.items.len != 0) try handleFilter(s, try s.a.dupe(u8, prev.items));
    try flushInbodyHeaderAccum(s);
}

/// git's `cleanup_subject`: `Re:`, `[...]` and leading whitespace and
/// colons off the front.
fn cleanupSubject(a: Allocator, subject_in: []const u8, keep_non_patch: bool) Allocator.Error![]const u8 {
    var subject: std.ArrayList(u8) = .empty;
    try subject.appendSlice(a, subject_in);
    var at: usize = 0;
    while (at < subject.items.len) {
        switch (subject.items[at]) {
            'r', 'R' => {
                if (subject.items.len <= at + 3) break;
                if ((subject.items[at + 1] == 'e' or subject.items[at + 1] == 'E') and subject.items[at + 2] == ':') {
                    subject.replaceRangeAssumeCapacity(at, 3, "");
                    continue;
                }
                at += 1;
                break;
            },
            ' ', '\t', ':' => {
                _ = subject.orderedRemove(at);
                continue;
            },
            '[' => {
                const close = std.mem.findScalarPos(u8, subject.items, at, ']') orelse break;
                const remove = close - at + 1;
                if (!keep_non_patch or (7 <= remove and std.mem.find(u8, subject.items[at .. at + remove], "PATCH") != null)) {
                    subject.replaceRangeAssumeCapacity(at, remove, "");
                } else {
                    at += remove;
                    if (at < subject.items.len and isSpace(subject.items[at])) at += 1;
                }
                continue;
            },
            else => break,
        }
    }
    return trim(subject.items);
}

fn handleFrom(s: *State, from: []const u8) Error!void {
    const a = s.a;
    var f: std.ArrayList(u8) = .empty;
    try unquoteQuotedPair(a, &f, cstr(from));
    const at_opt = std.mem.findScalar(u8, f.items, '@');
    if (at_opt == null) {
        // "John Doe <johndoe>"
        if (s.email.items.len != 0) return;
        const line = cstr(from);
        const bra = std.mem.findScalar(u8, line, '<') orelse return;
        const ket = std.mem.findScalarPos(u8, line, bra, '>') orelse return;
        s.email.clearRetainingCapacity();
        try s.email.appendSlice(a, line[bra + 1 .. ket]);
        s.name.clearRetainingCapacity();
        try s.name.appendSlice(a, trim(line[0..bra]));
        try saneName(s, s.name.items);
        return;
    }
    var at = at_opt.?;
    if (s.email.items.len != 0 and std.mem.findScalarPos(u8, f.items, at + 1, '@') != null) return;
    while (at > 0) {
        const c = f.items[at - 1];
        if (isSpace(c)) break;
        if (c == '<') {
            f.items[at - 1] = ' ';
            break;
        }
        at -= 1;
    }
    var el: usize = 0;
    while (at + el < f.items.len and std.mem.findScalar(u8, " \n\t\r\x0b\x0c>", f.items[at + el]) == null) el += 1;
    s.email.clearRetainingCapacity();
    try s.email.appendSlice(a, f.items[at .. at + el]);
    const remove = el + @intFromBool(at + el < f.items.len);
    f.replaceRangeAssumeCapacity(at, remove, "");
    var name = trim(try cleanupSpace(a, f.items));
    if (name.len > 0 and name[0] == '(' and name[name.len - 1] == ')') name = name[1 .. name.len - 1];
    try saneName(s, name);
}

fn saneName(s: *State, name: []const u8) Allocator.Error!void {
    const src = if (name.len == 0 or name.len > 60 or std.mem.findAny(u8, name, "@<>") != null) s.email.items else name;
    const copy = try s.a.dupe(u8, src);
    s.name.clearRetainingCapacity();
    try s.name.appendSlice(s.a, copy);
}

fn unquoteQuotedPair(a: Allocator, out: *std.ArrayList(u8), in: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < in.len) {
        const c = in[i];
        i += 1;
        switch (c) {
            '"' => {
                var literal = false;
                while (i < in.len) {
                    const d = in[i];
                    i += 1;
                    if (literal) {
                        literal = false;
                    } else if (d == '\\') {
                        literal = true;
                        continue;
                    } else if (d == '"') break;
                    try out.append(a, d);
                }
            },
            '(' => {
                try out.append(a, '(');
                var literal = false;
                var depth: usize = 1;
                while (i < in.len) {
                    const d = in[i];
                    i += 1;
                    if (literal) {
                        literal = false;
                    } else switch (d) {
                        '\\' => {
                            literal = true;
                            continue;
                        },
                        '(' => {
                            try out.append(a, '(');
                            depth += 1;
                            continue;
                        },
                        ')' => {
                            try out.append(a, ')');
                            depth -= 1;
                            if (depth == 0) break;
                            continue;
                        },
                        else => {},
                    }
                    try out.append(a, d);
                }
            },
            else => try out.append(a, c),
        }
    }
}

/// Take one message apart, as `git mailinfo` does.
pub fn info(gpa: Allocator, mail: []const u8, options: InfoOptions) Self.Error!Info {
    var result: Info = .{ .arena = .init(gpa) };
    errdefer result.arena.deinit();
    const a = result.arena.allocator();
    var s: State = .{ .a = a, .options = options, .input = mail };
    // leading whitespace, and nothing else, is an empty patch
    while (s.pos < mail.len and isSpace(mail[s.pos])) s.pos += 1;
    if (s.pos >= mail.len) return error.EmptyPatch;
    var rest: ?[]const u8 = null;
    while (try readOneHeaderLine(&s, &rest)) |line| _ = try checkHeader(&s, line, .primary, true);
    if (rest) |line| try handleBody(&s, line);
    if (s.input_error) |err| return err;

    result.message = s.log_message.items;
    result.patch = s.patch.items;
    result.quoted_cr = s.any_quoted_cr;
    result.format_flowed = s.format_flowed;
    var out: std.ArrayList(u8) = .empty;
    for (header_names, 0..) |name, i| {
        const hdr = if (s.patch_lines != 0 and s.s_hdr[i] != null) s.s_hdr[i].? else s.p_hdr[i] orelse continue;
        if (std.mem.findScalar(u8, hdr, 0) != null) return error.NulInHeader;
        if (std.mem.eql(u8, name, "Subject")) {
            var subject = hdr;
            if (!options.keep_subject) subject = try cleanupSpace(a, try cleanupSubject(a, hdr, options.keep_non_patch_brackets));
            var it = std.mem.splitScalar(u8, subject, '\n');
            while (it.next()) |l| try out.print(a, "Subject: {s}\n", .{l});
            result.subject = subject;
        } else if (std.mem.eql(u8, name, "From")) {
            try handleFrom(&s, try cleanupSpace(a, hdr));
            try out.print(a, "Author: {s}\nEmail: {s}\n", .{ s.name.items, s.email.items });
            result.author = s.name.items;
            result.email = s.email.items;
        } else {
            const v = try cleanupSpace(a, hdr);
            try out.print(a, "{s}: {s}\n", .{ name, v });
            result.date = v;
        }
    }
    try out.append(a, '\n');
    result.info = out.items;
    return result;
}

test "a mailbox is cut at its From lines, with CR LF made LF" {
    const gpa = std.testing.allocator;
    const mbox = "From abc Mon Sep 17 00:00:00 2001\r\nSubject: one\r\n\r\nbody\r\nFrom def Mon Sep 17 00:00:00 2001\nSubject: two\n\nFrom here is not a separator\n";
    var box = try split(gpa, mbox, .{});
    defer box.deinit();
    try std.testing.expectEqual(@as(usize, 2), box.messages.len);
    try std.testing.expectEqualStrings("From abc Mon Sep 17 00:00:00 2001\nSubject: one\n\nbody\n", box.messages[0]);
    try std.testing.expect(isFromLine("From e6807f3efca28b30decfecb1732a56c7db1137ee Mon Sep 17 00:00:00 2001\n"));
    try std.testing.expect(!isFromLine("From here is not a separator\n"));
}

test "a message comes apart into author, subject, date, message and patch" {
    const gpa = std.testing.allocator;
    const mail =
        \\From 1234 Mon Sep 17 00:00:00 2001
        \\From: =?UTF-8?q?J=C3=B6rg?= <jorg@example.com>
        \\Date: Tue, 14 Nov 2023 22:13:20 +0000
        \\Subject: [PATCH 1/2] Re: fix
        \\ the thing
        \\
        \\Body line.
        \\---
        \\ a | 1 +
        \\
        \\diff --git a/a b/a
        \\
    ;
    var got = try info(gpa, mail, .{});
    defer got.deinit();
    try std.testing.expectEqualStrings("Author: J\xc3\xb6rg\nEmail: jorg@example.com\nSubject: fix the thing\nDate: Tue, 14 Nov 2023 22:13:20 +0000\n\n", got.info);
    try std.testing.expectEqualStrings("Body line.\n", got.message);
    try std.testing.expectEqualStrings("---\n a | 1 +\n\ndiff --git a/a b/a\n", got.patch);
}

test "a message ending in a bare --- breaks to the patch there, as git's mailinfo does" {
    const gpa = std.testing.allocator;
    try std.testing.expect(patchbreak("--- "));
    try std.testing.expect(!patchbreak("---  x"));
    const plain = "From: A <a@example.com>\nSubject: s\n\nbody\n--- ";
    const encoded = "From: A <a@example.com>\nSubject: s\nContent-Transfer-Encoding: base64\n\nYm9keQ0KLS0tIA==\n";
    for ([_][]const u8{ plain, encoded }, [_][]const u8{ "body\n", "body\r\n" }) |mail, message| {
        var got = try info(gpa, mail, .{});
        defer got.deinit();
        try std.testing.expectEqualStrings(message, got.message);
        try std.testing.expectEqualStrings("--- ", got.patch);
    }
}

test "fuzz: any bytes split and come apart, or are refused by name" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [2048]u8 = undefined;
            const len = smith.slice(&buf);
            const input = buf[0..len];
            var box = split(std.testing.allocator, input, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return,
            };
            defer box.deinit();
            for (box.messages) |m| {
                var got = info(std.testing.allocator, m, .{ .scissors = true }) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => continue,
                };
                got.deinit();
            }
        }
    }.one, .{});
}
