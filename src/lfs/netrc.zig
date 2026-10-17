//! `~/.netrc`: a login and password per host, which git-lfs reads before it
//! asks any credential helper, with git-lfs's go-netrc (ba0029b). This reads
//! a file as that reader does.
//!
//! The file is a stream of tokens, each its leading white space (Unicode's,
//! as Go's `unicode.IsSpace` has it) and a word, or a `#` and the rest of its
//! line. `machine <name>` begins an entry and `default` one for any host; a
//! second `default`, or a `machine` after it, refuses the file. `login`,
//! `password` and `account` fill the entry in, each once; before an entry
//! they refuse the file. `macdef <name>` takes its name and nothing else: the
//! keywords of a macro's body are read as keywords, as go-netrc reads them.
//! Any other word is passed over. A keyword's value is the next token,
//! trimmed, whatever it is (a comment line among them), or empty at the end.
//! There are no quotes. The tokens are cut as Go's `bufio.Scanner` cuts them,
//! through its buffer of 4 KiB growing to 64 KiB: white space at the buffer's
//! end is a token of its own, and a token that does not end within 64 KiB
//! refuses the file.

const ErrorNamespace = @This();
const std = @import("std");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;

/// One entry.
pub const Machine = struct {
    /// The host; empty for the `default` entry, which a `machine` with no
    /// name also is.
    name: []const u8,
    login: []const u8 = "",
    password: []const u8 = "",
    account: []const u8 = "",

    /// Whether this is the `default` entry: one with no name.
    pub fn isDefault(m: Machine) bool {
        return m.name.len == 0;
    }
};

/// A parsed file. Every slice is owned by its arena.
pub const Netrc = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    machines: []const Machine,

    /// Errors from `parse`.
    pub const ParseError = Allocator.Error || error{MalformedNetrc};

    /// Read `text`, which is not kept. A file go-netrc refuses is
    /// `error.MalformedNetrc`, and git-lfs then uses none.
    pub fn parse(gpa: Allocator, text: []const u8) ParseError!Netrc {
        var n: Netrc = .{ .arena = .init(gpa), .machines = &.{} };
        errdefer n.arena.deinit();
        const a = n.arena.allocator();
        var machines: std.ArrayList(Machine) = .empty;
        var scanner: Scanner = .{ .text = text };
        var default_seen = false;
        var current: ?Machine = null;
        while (try scanner.next()) |raw| {
            if (raw.len == 0) break;
            const keyword = keywordOf(raw) orelse continue;
            switch (keyword) {
                .comment => {},
                .macdef => _ = try scanner.value(),
                .default, .machine => {
                    if (default_seen) return error.MalformedNetrc;
                    if (current) |m| try machines.append(a, m);
                    current = .{ .name = "" };
                    if (keyword == .default) {
                        default_seen = true;
                    } else current.?.name = try a.dupe(u8, try scanner.value());
                },
                .login, .password, .account => {
                    const m = if (current) |*m| m else return error.MalformedNetrc;
                    const field = switch (keyword) {
                        .login => &m.login,
                        .password => &m.password,
                        else => &m.account,
                    };
                    if (field.len != 0) return error.MalformedNetrc;
                    field.* = try a.dupe(u8, try scanner.value());
                },
            }
        }
        if (current) |m| try machines.append(a, m);
        n.machines = machines.items;
        return n;
    }

    /// The entry for `host` whose login is `login` when one is given, else
    /// the `default` entry, as go-netrc's `FindMachine` finds it.
    pub fn find(n: *const Netrc, host: []const u8, login: ?[]const u8) ?Machine {
        var fallback: ?Machine = null;
        for (n.machines) |m| {
            if (std.mem.eql(u8, m.name, host)) {
                if (login) |l| if (l.len != 0 and !std.mem.eql(u8, l, m.login)) continue;
                return m;
            }
            if (m.isDefault()) fallback = m;
        }
        return fallback;
    }

    /// Release everything.
    pub fn deinit(n: *Netrc) void {
        n.arena.deinit();
        n.* = undefined;
    }
};

const Keyword = enum { machine, default, login, password, account, macdef, comment };

/// What a token's first word makes it, or `null` for a word go-netrc passes
/// over.
fn keywordOf(raw: []const u8) ?Keyword {
    var at: usize = 0;
    while (at < raw.len) {
        const r = decode(raw[at..]);
        if (!isSpace(r.rune)) break;
        at += r.len;
    }
    const start = at;
    while (at < raw.len) {
        const r = decode(raw[at..]);
        if (isSpace(r.rune)) break;
        at += r.len;
    }
    const word = raw[start..at];
    // White space alone, or a `#` and what follows: a comment, as go-netrc
    // takes both.
    if (word.len == 0 or word[0] == '#') return .comment;
    const k = std.meta.stringToEnum(Keyword, word) orelse return null;
    return if (k == .comment) null else k;
}

/// The largest token Go's `bufio.Scanner` holds, and the buffer it starts with.
const max_token = 64 * 1024;
const start_buffer = 4096;

/// The tokens of a text as a `bufio.Scanner` reading it from a
/// `bytes.Reader` cuts them with go-netrc's split function: the buffer, what
/// it holds and when it reads more are the Scanner's.
const Scanner = struct {
    text: []const u8,
    /// How much of `text` has been read into the buffer.
    read: usize = 0,
    capacity: usize = 0,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,

    /// The next token, which may be empty at the end of the text; `null`
    /// when there are no more.
    fn next(s: *Scanner) error{MalformedNetrc}!?[]const u8 {
        while (true) {
            if (s.end > s.start or s.eof) {
                // The buffer holds the text from `read` back to `start`.
                const from = s.read - (s.end - s.start);
                const data = s.text[from..s.read];
                if (split(data, s.eof)) |cut| {
                    s.start += cut;
                    return data[0..cut];
                }
            }
            if (s.eof) return null;
            if (s.start > 0 and (s.end == s.capacity or s.start > s.capacity / 2)) {
                s.end -= s.start;
                s.start = 0;
            }
            if (s.end == s.capacity) {
                // Go's `ErrTooLong`.
                if (s.capacity >= max_token) return error.MalformedNetrc;
                s.capacity = if (s.capacity == 0) start_buffer else @min(s.capacity * 2, max_token);
                s.end -= s.start;
                s.start = 0;
            }
            const n = @min(s.capacity - s.end, s.text.len - s.read);
            if (n == 0) {
                s.eof = true;
            } else {
                s.read += n;
                s.end += n;
            }
        }
    }

    /// A keyword's value: the next token, trimmed, or empty at the end.
    fn value(s: *Scanner) error{MalformedNetrc}![]const u8 {
        const raw = (try s.next()) orelse return "";
        return trim(raw);
    }
};

/// How much of `data` the next token takes, the token being `data` up to
/// there, or `null` when more input is needed: go-netrc's
/// `scanTokensKeepPrefix`, and `scanLinesKeepPrefix` for a comment.
fn split(data: []const u8, at_eof: bool) ?usize {
    var start: usize = 0;
    while (start < data.len) {
        const r = decode(data[start..]);
        if (!isSpace(r.rune)) break;
        start += r.len;
    }
    if (start == data.len) return data.len;
    if (data[start] == '#') {
        if (std.mem.findScalarPos(u8, data, start, '\n')) |line_end| return line_end;
        return if (at_eof) data.len else null;
    }
    var at = start;
    while (at < data.len) {
        const r = decode(data[at..]);
        if (isSpace(r.rune)) return at;
        at += r.len;
    }
    return if (at_eof) data.len else null;
}

/// `text` without the white space at either end, as Go's `strings.TrimSpace`.
fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len) {
        const r = decode(text[start..]);
        if (!isSpace(r.rune)) break;
        start += r.len;
    }
    var end = text.len;
    while (end > start) {
        const r = decodeLast(text[start..end]);
        if (!isSpace(r.rune)) break;
        end -= r.len;
    }
    return text[start..end];
}

const Rune = struct { rune: u21, len: usize };
const replacement: u21 = 0xfffd;

/// The rune `bytes` begins with, as Go's `utf8.DecodeRune`: U+FFFD one byte
/// long for a byte that begins no sequence.
fn decode(bytes: []const u8) Rune {
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .rune = replacement, .len = 1 };
    if (n > bytes.len) return .{ .rune = replacement, .len = 1 };
    const decoded = switch (n) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        else => std.unicode.utf8Decode4(bytes[0..4].*),
    };
    const rune = decoded catch return .{ .rune = replacement, .len = 1 };
    return .{ .rune = rune, .len = n };
}

/// The rune `bytes` ends with, as Go's `utf8.DecodeLastRune`.
fn decodeLast(bytes: []const u8) Rune {
    const end = bytes.len;
    if (bytes[end - 1] < 0x80) return .{ .rune = bytes[end - 1], .len = 1 };
    const limit = end -| 4;
    var start = end - 1;
    while (start > limit and bytes[start] & 0xc0 == 0x80) start -= 1;
    const r = decode(bytes[start..end]);
    if (start + r.len != end) return .{ .rune = replacement, .len = 1 };
    return r;
}

/// Go's `unicode.IsSpace`: the Latin-1 white space and Unicode's White_Space.
fn isSpace(r: u21) bool {
    return switch (r) {
        '\t', '\n', 0x0b, 0x0c, '\r', ' ', 0x85, 0xa0 => true,
        0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

const testing = std.testing;

test "a netrc's entries are found as go-netrc finds them" {
    var n = try Netrc.parse(testing.allocator,
        \\# a comment
        \\machine git.example.com login ada password secret
        \\machine git.example.com
        \\    login bob
        \\    password "hunter 2"
        \\macdef init
        \\echo machine evil login x password y
        \\
        \\default login anonymous password p
        \\
    );
    defer n.deinit();
    try testing.expectEqualStrings("secret", n.find("git.example.com", null).?.password);
    // No quotes: a word ends at white space.
    try testing.expectEqualStrings("\"hunter", n.find("git.example.com", "bob").?.password);
    try testing.expectEqualStrings("p", n.find("other.example.com", null).?.password);
    // A macro's keywords are read.
    try testing.expectEqualStrings("y", n.find("evil", null).?.password);
    try testing.expectError(error.MalformedNetrc, Netrc.parse(testing.allocator, "login before machine"));
    try testing.expectError(error.MalformedNetrc, Netrc.parse(testing.allocator, "default\nmachine h"));
    try testing.expectError(error.MalformedNetrc, Netrc.parse(testing.allocator, "machine h login a login b"));
    // A name at the end is empty, which is the default's.
    var bare = try Netrc.parse(testing.allocator, "machine");
    defer bare.deinit();
    try testing.expect(bare.find("anything", null).?.isDefault());
}

test "tokens are cut where Go's bufio.Scanner cuts them" {
    const gpa = testing.allocator;
    // White space reaching the end of the 4 KiB buffer is a token of its
    // own, which a keyword then takes as its value: go-netrc's answers.
    const spaced = try std.mem.concat(gpa, u8, &.{ "machine", &@as([4100]u8, @splat(' ')), "h login ada" });
    defer gpa.free(spaced);
    var n = try Netrc.parse(gpa, spaced);
    defer n.deinit();
    try testing.expectEqual(@as(usize, 1), n.machines.len);
    try testing.expectEqualStrings("", n.machines[0].name);
    try testing.expectEqualStrings("ada", n.machines[0].login);
    // A token that does not end within 64 KiB of where it begins, its white
    // space included, refuses the file, unless the file ends sooner.
    const long = try std.mem.concat(gpa, u8, &.{ "machine ", &@as([64 * 1024]u8, @splat('x')), " login a" });
    defer gpa.free(long);
    try testing.expectError(error.MalformedNetrc, Netrc.parse(gpa, long));
    try testing.expectError(error.MalformedNetrc, Netrc.parse(gpa, long[0 .. "machine ".len + 65535]));
    var fits = try Netrc.parse(gpa, long[0 .. "machine ".len + 65534]);
    defer fits.deinit();
    try testing.expectEqual(@as(usize, 65534), fits.machines[0].name.len);
}

test "netrc files are read as go-netrc reads them" {
    // 400 random files of keywords, words, comments and white space (Unicode's
    // too, and bytes that are not UTF-8), each with go-netrc's answer: `ERR`,
    // or the entry `FindMachine` gives for each query below, in hex.
    const queries = [_]struct { []const u8, []const u8 }{ .{ "h", "" }, .{ "h", "ada" }, .{ "h", "bob" }, .{ "g.example", "" }, .{ "g.example", "ada" }, .{ "", "" }, .{ "x", "" }, .{ "#c", "" } };
    var lines = std.mem.splitScalar(u8, @embedFile("../testing/lfs/go_netrc.tsv"), '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.findScalar(u8, line, '\t').?;
        const text = try testing.allocator.alloc(u8, tab / 2);
        defer testing.allocator.free(text);
        _ = try std.fmt.hexToBytes(text, line[0..tab]);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        if (Netrc.parse(testing.allocator, text)) |parsed| {
            var n = parsed;
            defer n.deinit();
            for (queries) |q| {
                const m = n.find(q[0], q[1]) orelse {
                    try out.writer.writeAll("nil,");
                    continue;
                };
                try out.writer.print("M({x};{x};{x};{x}),", .{ m.name, m.login, m.password, m.account });
            }
        } else |err| switch (err) {
            error.MalformedNetrc => try out.writer.writeAll("ERR"),
            else => return err,
        }
        try testing.expectEqualStrings(line[tab + 1 ..], out.written());
        cases += 1;
    }
    try testing.expectEqual(@as(usize, 400), cases);
}

test "fuzz: any netrc is read or refused by name" {
    try shakedown.check(testing.allocator, {}, fuzzNetrc, .{});
}

fn fuzzNetrc(_: void, case: *shakedown.Case) anyerror!void {
    var scratch: [512]u8 = undefined;
    const len = shakedown.gen.intRange(case.source, usize, 0, scratch.len);
    case.source.bytes(scratch[0..len]);
    var n = Netrc.parse(testing.allocator, scratch[0..len]) catch |err| switch (err) {
        error.MalformedNetrc => return,
        else => return err,
    };
    defer n.deinit();
    for (n.machines) |m| _ = n.find(m.name, m.login);
}

/// All errors reported by this namespace.
pub const Error = Netrc.ParseError;
