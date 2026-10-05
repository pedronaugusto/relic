//! Commit messages as git's commands shape them.
//!
//! A cherry-pick with `-x` or `--signoff`, a revert, a squash: each builds a
//! message from another one, and the result is part of a commit's name, so
//! every byte is git's. The rules here are git's own: where the trailer
//! block starts -- the last paragraph, when it is all trailers or a quarter
//! trailers with at least one git wrote itself -- whether a blank line goes
//! before a new trailer, how a message is cleaned of comments and blank
//! lines, and which line is a commit's subject. Messages are read from
//! commits and from files a person may have edited, so every function here
//! takes arbitrary bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const object = @import("../object.zig");
const trailer = @import("trailer.zig");
const config_mod = @import("../config.zig");

/// How a message is cleaned before it is committed: `commit.cleanup`.
pub const Cleanup = enum {
    /// Leave it exactly as it is.
    verbatim,
    /// Remove trailing whitespace from every line, blank lines at either
    /// end, and runs of blank lines inside.
    whitespace,
    /// `whitespace`, and also every line beginning with the comment
    /// string.
    strip,

    /// The mode a `commit.cleanup` value names, or `null`. `scissors`
    /// cleans as `whitespace` does wherever no cut line is involved, which
    /// is everywhere a message is not edited.
    pub fn parse(text: []const u8) ?Cleanup {
        if (std.mem.eql(u8, text, "verbatim")) return .verbatim;
        if (std.mem.eql(u8, text, "whitespace")) return .whitespace;
        if (std.mem.eql(u8, text, "scissors")) return .whitespace;
        if (std.mem.eql(u8, text, "strip")) return .strip;
        return null;
    }
};

/// The line `git commit -v` puts above the diff, after the comment string
/// and a space.
pub const cut_line = "------------------------ >8 ------------------------";

/// The prefix of the line `-x` adds.
pub const cherry_picked_prefix = "(cherry picked from commit ";

/// git's `isspace`, which is narrower than C's: no vertical tab and no form
/// feed.
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// `strbuf_stripspace`: trailing whitespace off every line, comment lines
/// out when `comment` is given, blank lines off both ends, and a run of
/// blank lines inside collapsed to one. What remains ends in a newline, or
/// is empty. The result is the caller's.
pub fn stripSpace(gpa: Allocator, text: []const u8, comment: ?[]const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var empties: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, at, '\n')) |nl| nl + 1 else text.len;
        const line = text[at..end];
        at = end;
        if (comment) |prefix| {
            if (std.mem.startsWith(u8, line, prefix)) continue;
        }
        var len = line.len;
        while (len > 0 and isSpace(line[len - 1])) len -= 1;
        if (len == 0) {
            empties += 1;
            continue;
        }
        if (empties > 0 and out.items.len > 0) try out.append(gpa, '\n');
        empties = 0;
        try out.appendSlice(gpa, line[0..len]);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// Clean `text` as `mode` says. The result is the caller's.
pub fn cleanup(gpa: Allocator, text: []const u8, mode: Cleanup, comment: []const u8) Allocator.Error![]u8 {
    return switch (mode) {
        .verbatim => gpa.dupe(u8, text),
        .whitespace => stripSpace(gpa, text, null),
        .strip => stripSpace(gpa, text, comment),
    };
}

/// Where a line that is all whitespace ends: whether `line` is blank.
fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c == '\n') return true;
        if (!isSpace(c)) return false;
    }
    return true;
}

fn nextLine(buf: []const u8, at: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, buf, at, '\n')) |nl| nl + 1 else buf.len;
}

/// How a repository reads trailers: its `trailer.*` settings, with the
/// comment string `core.commentChar` names (`#` for `auto`). Everything is
/// `arena`'s.
pub fn trailerSettings(arena: Allocator, config: *const config_mod.Config) Allocator.Error!trailer.Settings {
    return trailer.Settings.load(arena, config, commentString(config.get("core.commentchar"), ""));
}

/// What `has_conforming_footer` says of a message: no trailer block, one
/// without the line asked about, one with it but not last, or one ending
/// with it.
pub const Footer = enum { none, trailers, has_line, ends_with_line };

/// Whether `msg` ends in a trailer block, and whether `line` -- the whole
/// line, newline included -- is in it and last: git's
/// `has_conforming_footer`, reading trailers as `settings` say.
pub fn conformingFooter(gpa: Allocator, msg: []const u8, line: ?[]const u8, settings: trailer.Settings) Allocator.Error!Footer {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const lines = try trailer.iterate(arena_state.allocator(), settings, msg);
    if (lines.len == 0) return .none;
    var found: usize = 0;
    for (lines, 1..) |t, n| {
        if (line) |wanted| {
            if (std.mem.startsWith(u8, t.raw, wanted)) found = n;
        }
    }
    if (found != 0 and found == lines.len) return .ends_with_line;
    if (found != 0) return .has_line;
    return .trailers;
}

/// Make the message end in a newline, as `strbuf_complete_line` does.
fn completeLine(gpa: Allocator, msg: *std.ArrayList(u8)) Allocator.Error!void {
    if (msg.items.len != 0 and msg.items[msg.items.len - 1] != '\n') try msg.append(gpa, '\n');
}

/// `-x`: the line naming the commit a pick came from, after a blank line
/// unless the message already ends in trailers.
pub fn appendCherryPicked(gpa: Allocator, msg: *std.ArrayList(u8), hex: []const u8, settings: trailer.Settings) Allocator.Error!void {
    try completeLine(gpa, msg);
    if (try conformingFooter(gpa, msg.items, null, settings) == .none) try msg.append(gpa, '\n');
    try msg.appendSlice(gpa, cherry_picked_prefix);
    try msg.appendSlice(gpa, hex);
    try msg.appendSlice(gpa, ")\n");
}

/// `--signoff`: `Signed-off-by: Name <email>`, after a blank line unless the
/// message already ends in trailers, and not again when it is already the
/// last one.
pub fn appendSignoff(gpa: Allocator, msg: *std.ArrayList(u8), who: object.Signature, settings: trailer.Settings) Allocator.Error!void {
    const line = try std.fmt.allocPrint(gpa, "Signed-off-by: {s} <{s}>\n", .{ who.name, who.email });
    defer gpa.free(line);
    try completeLine(gpa, msg);
    const footer: Footer = if (std.mem.eql(u8, msg.items, line))
        .ends_with_line
    else
        try conformingFooter(gpa, msg.items, line, settings);
    if (footer == .none) {
        const len = msg.items.len;
        if (len == 0) {
            try msg.appendSlice(gpa, "\n\n");
        } else if (len == 1) {
            try msg.append(gpa, '\n');
        } else if (msg.items[len - 2] != '\n') {
            try msg.append(gpa, '\n');
        }
    }
    if (footer != .ends_with_line) try msg.appendSlice(gpa, line);
}

/// `find_commit_subject`: a commit message from its first line that is not
/// blank. The subject is that line.
pub fn fromSubject(msg: []const u8) []const u8 {
    var at: usize = 0;
    while (at < msg.len) {
        const next = nextLine(msg, at);
        if (!isBlankLine(msg[at..next])) break;
        at = next;
    }
    return msg[at..];
}

/// The subject git labels a commit with in a conflict and names it by in a
/// cherry-pick's `todo`: the first line that is not blank, without its
/// newline.
pub fn subjectLine(msg: []const u8) []const u8 {
    const from = fromSubject(msg);
    const end = std.mem.indexOfScalar(u8, from, '\n') orelse from.len;
    return from[0..end];
}

/// `%s`: the first paragraph, each line without its trailing whitespace,
/// joined by single spaces -- what a rebase's `todo` names a commit by. The
/// result is the caller's.
pub fn onelineSubject(gpa: Allocator, msg: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var at: usize = 0;
    // Blank lines before the subject are no part of it.
    while (at < msg.len) {
        const next = nextLine(msg, at);
        if (!isBlankLine(msg[at..next])) break;
        at = next;
    }
    while (at < msg.len) {
        const next = nextLine(msg, at);
        var line = msg[at..next];
        while (line.len > 0 and isSpace(line[line.len - 1])) line = line[0 .. line.len - 1];
        if (line.len == 0) break;
        if (out.items.len != 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, line);
        at = next;
    }
    return out.toOwnedSlice(gpa);
}

/// The comment string `core.commentChar` (or `core.commentString`) names:
/// `#` when it is unset. `auto` picks the first of git's candidates no
/// line of `msg` begins with.
pub fn commentString(setting: ?[]const u8, msg: []const u8) []const u8 {
    const text = setting orelse return "#";
    if (!std.mem.eql(u8, text, "auto")) return if (text.len == 0) "#" else text;
    const candidates = "#;@!$%^&|:";
    for (0..candidates.len) |i| {
        const candidate = candidates[i .. i + 1];
        var used = false;
        var at: usize = 0;
        while (at < msg.len) : (at = nextLine(msg, at)) {
            var p = at;
            while (p < msg.len and (msg[p] == ' ' or msg[p] == '\t')) p += 1;
            if (p < msg.len and msg[p] == candidate[0]) used = true;
        }
        if (!used) return candidate;
    }
    return "#";
}

//=========================================================================
// Tests
//=========================================================================

const testgit = @import("../testing/git.zig");

test "stripping space matches git stripspace, comments in and out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    const inputs = [_][]const u8{
        "",
        "\n\n",
        "subject   \n\n\n\nbody\t\n\n",
        "  leading\n# comment\nkept # not a comment\n\n\n#tail\n",
        "no newline at the end",
        "a\r\n\r\nb\r\n",
        "\x0bvertical tab stays\x0b\n",
    };
    for (inputs) |input| {
        for ([_]bool{ false, true }) |strip_comments| {
            const args: []const []const u8 = if (strip_comments)
                &.{ "stripspace", "--strip-comments" }
            else
                &.{"stripspace"};
            const expected = try repo.runInput(io, args, input);
            defer gpa.free(expected);
            const got = try stripSpace(gpa, input, if (strip_comments) "#" else null);
            defer gpa.free(got);
            try std.testing.expectEqualStrings(expected, got);
        }
    }
}

test "a subject is the first line that is not blank, and a oneline subject its paragraph" {
    const gpa = std.testing.allocator;
    const msg = "\n  \nfirst line  \nsecond line\n\nbody\n";
    try std.testing.expectEqualStrings("first line  ", subjectLine(msg));
    try std.testing.expectEqualStrings("first line  \nsecond line\n\nbody\n", fromSubject(msg));
    const oneline = try onelineSubject(gpa, msg);
    defer gpa.free(oneline);
    try std.testing.expectEqualStrings("first line second line", oneline);
}

test "a sign-off goes after a blank line, joins a trailer block, and is not repeated last" {
    const gpa = std.testing.allocator;
    const who: object.Signature = .{ .name = "A U Thor", .email = "a@example.com", .when_secs = 0, .offset_minutes = 0 };
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "subject\n", .out = "subject\n\nSigned-off-by: A U Thor <a@example.com>\n" },
        .{ .in = "subject", .out = "subject\n\nSigned-off-by: A U Thor <a@example.com>\n" },
        .{ .in = "subject\n\nbody\n", .out = "subject\n\nbody\n\nSigned-off-by: A U Thor <a@example.com>\n" },
        .{ .in = "subject\n\nAcked-by: B <b@x>\n", .out = "subject\n\nAcked-by: B <b@x>\nSigned-off-by: A U Thor <a@example.com>\n" },
        .{ .in = "subject\n\nSigned-off-by: A U Thor <a@example.com>\n", .out = "subject\n\nSigned-off-by: A U Thor <a@example.com>\n" },
        .{ .in = "subject\n\nSigned-off-by: A U Thor <a@example.com>\nAcked-by: B <b@x>\n", .out = "subject\n\nSigned-off-by: A U Thor <a@example.com>\nAcked-by: B <b@x>\nSigned-off-by: A U Thor <a@example.com>\n" },
        .{ .in = "", .out = "\n\nSigned-off-by: A U Thor <a@example.com>\n" },
        // One line: a title is never a trailer block.
        .{ .in = "Acked-by: B <b@x>\n", .out = "Acked-by: B <b@x>\n\nSigned-off-by: A U Thor <a@example.com>\n" },
        // A quarter trailers with one git wrote itself is a trailer block.
        .{ .in = "subject\n\nsome text\n(cherry picked from commit 1234)\nmore text\nand more\n", .out = "subject\n\nsome text\n(cherry picked from commit 1234)\nmore text\nand more\nSigned-off-by: A U Thor <a@example.com>\n" },
    };
    for (cases) |case| {
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(gpa);
        try msg.appendSlice(gpa, case.in);
        try appendSignoff(gpa, &msg, who, .{});
        try std.testing.expectEqualStrings(case.out, msg.items);
    }
}

test "fuzz: trailer detection and cleanup take any bytes" {
    try std.testing.fuzz({}, fuzzMessage, .{});
}

fn fuzzMessage(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const text = buf[0..smith.slice(&buf)];
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const block = try trailer.block(arena_state.allocator(), .{}, text, true);
    try std.testing.expect(block.start <= text.len);
    try std.testing.expect(block.end <= text.len);
    _ = try conformingFooter(gpa, text, "Signed-off-by: A <a@b>\n", .{});
    const stripped = try stripSpace(gpa, text, "#");
    defer gpa.free(stripped);
    // Stripping twice changes nothing more.
    const again = try stripSpace(gpa, stripped, "#");
    defer gpa.free(again);
    try std.testing.expectEqualStrings(stripped, again);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    try msg.appendSlice(gpa, text);
    try appendSignoff(gpa, &msg, .{ .name = "A", .email = "a@b", .when_secs = 0, .offset_minutes = 0 }, .{});
    try std.testing.expect(std.mem.endsWith(u8, msg.items, "Signed-off-by: A <a@b>\n"));
    const subject = try onelineSubject(gpa, text);
    gpa.free(subject);
    _ = commentString("auto", text);
}
