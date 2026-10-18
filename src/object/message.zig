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
const ctype = @import("../text.zig").ctype;
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;

const object = @import("object.zig");
const trailer = @import("trailer.zig");
const config_mod = @import("../config/config.zig");

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
    /// `whitespace` after cutting the message at the scissors line, as
    /// `git commit` cleans a message an editor showed.
    scissors,

    /// The mode a `commit.cleanup` value names, or `null`.
    pub fn parse(text: []const u8) ?Cleanup {
        if (std.mem.eql(u8, text, "verbatim")) return .verbatim;
        if (std.mem.eql(u8, text, "whitespace")) return .whitespace;
        if (std.mem.eql(u8, text, "scissors")) return .scissors;
        if (std.mem.eql(u8, text, "strip")) return .strip;
        return null;
    }
};

/// git's `get_cleanup_mode`, which `git commit` and `git merge` read
/// `commit.cleanup` (or `--cleanup`) with: unset and `default` are `strip`
/// when an editor runs and `whitespace` when none does; `scissors` is
/// `whitespace` when none does; any other value is refused, as git dies on
/// it. `null` is unset.
pub fn cleanupMode(text: ?[]const u8, editor: bool) error{InvalidCleanupMode}!Cleanup {
    const t = text orelse return if (editor) .strip else .whitespace;
    if (std.mem.eql(u8, t, "default")) return if (editor) .strip else .whitespace;
    const mode = Cleanup.parse(t) orelse return error.InvalidCleanupMode;
    return if (mode == .scissors and !editor) .whitespace else mode;
}

/// `commit.cleanup` as `git commit` and `git merge` keep it: the last
/// value, `null` when unset, and refused if any is a bare name with no
/// value, as git's `git_config_string` dies on one.
pub fn cleanupSetting(config: *const config_mod.Config) error{InvalidCleanupMode}!?[]const u8 {
    var last: ?[]const u8 = null;
    var it = config.iterate(&.{"commit.cleanup"});
    while (it.next()) |entry| last = entry.value orelse return error.InvalidCleanupMode;
    return last;
}

/// `commit.cleanup` as `git commit` reads it with no editor.
pub fn commitCleanup(config: *const config_mod.Config) error{InvalidCleanupMode}!Cleanup {
    return cleanupMode(try cleanupSetting(config), false);
}

/// `commit.cleanup` as git's sequencer reads it for a pick, a revert or a
/// rebase: each value it knows replaces the one before, one it does not
/// is passed over with a warning; a bare name with no value is refused, as
/// git's `config_error_nonbool` dies. `null` when no value named a mode:
/// then the message is left as it is, or with `-x` or `--signoff` cleaned
/// of whitespace (`sequencerDefault`); a mode set here is git's explicit
/// cleanup, which those two follow too.
pub fn sequencerCleanup(config: *const config_mod.Config) error{InvalidCleanupMode}!?Cleanup {
    var mode: ?Cleanup = null;
    var it = config.iterate(&.{"commit.cleanup"});
    while (it.next()) |entry| mode = Cleanup.parse(entry.value orelse return error.InvalidCleanupMode) orelse mode;
    return mode;
}

/// The cleanup git's `try_to_commit` gives a message `mode` was asked for:
/// it cuts nothing, so `scissors` is `whitespace` there.
pub fn uncut(mode: Cleanup) Cleanup {
    return if (mode == .scissors) .whitespace else mode;
}

/// How git's `try_to_commit` cleans a message no cleanup was set for:
/// whitespace with `-x` or `--signoff`, else not at all.
pub fn sequencerDefault(trailers_added: bool) Cleanup {
    return if (trailers_added) .whitespace else .verbatim;
}

/// The last value of `name`, `null` when unset; a bare name with no value
/// is refused, as git's `git_config_string` dies on one for every command.
fn lastString(config: *const config_mod.Config, name: []const u8) error{InvalidEncodingSetting}!?[]const u8 {
    var last: ?[]const u8 = null;
    var it = config.iterate(&.{name});
    while (it.next()) |entry| last = entry.value orelse return error.InvalidEncodingSetting;
    return last;
}

/// git's `get_commit_output_encoding`: `i18n.commitEncoding`, the
/// encoding a new commit's message is in and named in its `encoding`
/// header when it is not UTF-8, and the one the sequencer converts a
/// picked message into; UTF-8 when unset. A bare name is refused.
pub fn commitEncoding(config: *const config_mod.Config) error{InvalidEncodingSetting}![]const u8 {
    return try lastString(config, "i18n.commitencoding") orelse "UTF-8";
}

/// git's `get_log_output_encoding`: `i18n.logOutputEncoding`, the
/// encoding `git log`, `git shortlog` and `git format-patch` write a
/// commit's message in, `commitEncoding` when unset. A bare name is
/// refused.
pub fn logOutputEncoding(config: *const config_mod.Config) error{InvalidEncodingSetting}![]const u8 {
    return try lastString(config, "i18n.logoutputencoding") orelse commitEncoding(config);
}

/// The comment string: `core.commentChar` and `core.commentString`, which
/// git reads as one setting, the last of either set deciding.
pub const Comment = union(enum) {
    /// The string lines begin with to be comments.
    string: []const u8,
    /// `auto`: `#`, except for the message `git commit` makes a commit from,
    /// where it is the first of git's candidates no line of the message
    /// begins with.
    auto,

    pub const default: Comment = .{ .string = "#" };

    /// The repository's setting, the last value of either name deciding.
    /// Refused where git dies, whichever value it is: a bare name with no
    /// value, an empty string, or one holding a line break.
    pub fn read(config: *const config_mod.Config) error{InvalidCommentString}!Comment {
        var comment: Comment = default;
        var it = config.iterate(&.{ "core.commentchar", "core.commentstring" });
        while (it.next()) |entry| {
            const value = entry.value orelse return error.InvalidCommentString;
            if (std.ascii.eqlIgnoreCase(value, "auto")) {
                comment = .auto;
                continue;
            }
            if (value.len == 0 or std.mem.findScalar(u8, value, '\n') != null) return error.InvalidCommentString;
            comment = .{ .string = value };
        }
        return comment;
    }

    /// The string, wherever git does not choose by a message: `auto` is
    /// `#`.
    pub fn text(c: Comment) []const u8 {
        return switch (c) {
            .string => |s| s,
            .auto => "#",
        };
    }

    /// The string for `msg`, the message a commit is about to be made from,
    /// as `git commit` takes it: git's `adjust_comment_line_char` for
    /// `auto` -- `#` if the message has none at all, else the first of
    /// `#;@!$%^&|:` that begins none of its lines before the comments and
    /// blank lines at its end (or the old `Conflicts:` block), the first
    /// line included -- and refused when every candidate is taken, as git
    /// dies.
    pub fn forMessage(c: Comment, msg: []const u8) error{NoCommentCharacter}![]const u8 {
        if (c == .string) return c.string;
        const candidates = "#;@!$%^&|:";
        if (std.mem.findScalar(u8, msg, candidates[0]) == null) return candidates[0..1];
        var taken: [candidates.len]bool = @splat(false);
        const cutoff = msg.len - trailer.ignoredBytes(msg, msg.len, "#");
        if (msg.len > 0) {
            if (std.mem.findScalar(u8, candidates, msg[0])) |i| taken[i] = true;
        }
        var p: usize = 0;
        while (p + 1 < cutoff) : (p += 1) {
            if ((msg[p] == '\n' or msg[p] == '\r') and msg[p + 1] != 0) {
                if (std.mem.findScalar(u8, candidates, msg[p + 1])) |i| taken[i] = true;
            }
        }
        for (taken, 0..) |t, i| if (!t) return candidates[i .. i + 1];
        return error.NoCommentCharacter;
    }
};

/// The scissors line, after the comment string and a space.
pub const cut_line = trailer.cut_line;

/// `strbuf_add_commented_lines`: each line of `text` after the comment
/// string, a space between them unless the line is empty or starts with a
/// tab, and `out` ended with a newline.
pub fn appendCommented(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8, comment: []const u8) Allocator.Error!void {
    var at: usize = 0;
    while (at < text.len) {
        const next = if (std.mem.findScalarPos(u8, text, at, '\n')) |nl| nl + 1 else text.len;
        try out.appendSlice(gpa, comment);
        if (text[at] != '\n' and text[at] != '\t') try out.append(gpa, ' ');
        try out.appendSlice(gpa, text[at..next]);
        at = next;
    }
    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
}

/// git's `append_conflicts_hint`: the `Conflicts:` list a stopped merge,
/// pick or revert leaves under its message, each path once, commented;
/// under the scissors line when the cleanup is `scissors`, so that an
/// editor's cleanup cuts it off.
pub fn appendConflictsHint(gpa: Allocator, out: *std.ArrayList(u8), paths: []const []const u8, comment: []const u8, mode: Cleanup) Allocator.Error!void {
    if (mode == .scissors) {
        try out.append(gpa, '\n');
        try appendCommented(gpa, out, cut_line ++ "\n", comment);
        try appendCommented(gpa, out, "Do not modify or remove the line above.\nEverything below it will be ignored.", comment);
        try out.appendSlice(gpa, comment);
    }
    try out.append(gpa, '\n');
    try appendCommented(gpa, out, "Conflicts:\n", comment);
    for (paths) |path| {
        // `strbuf_commented_addf` of `\t<path>\n`: the tab is the line's
        // own, so no space follows the comment string.
        const line = try std.mem.concat(gpa, u8, &.{ "\t", path, "\n" });
        defer gpa.free(line);
        try appendCommented(gpa, out, line, comment);
    }
}

/// The prefix of the line `-x` adds.
pub const cherry_picked_prefix = "(cherry picked from commit ";

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
        const end = if (std.mem.findScalarPos(u8, text, at, '\n')) |nl| nl + 1 else text.len;
        const line = text[at..end];
        at = end;
        if (comment) |prefix| {
            if (std.mem.startsWith(u8, line, prefix)) continue;
        }
        var len = line.len;
        while (len > 0 and ctype.isSpace(line[len - 1])) len -= 1;
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
        .scissors => stripSpace(gpa, text[0..trailer.locateEnd(text, comment, text.len)], null),
        .strip => stripSpace(gpa, text, comment),
    };
}

/// Where a line that is all whitespace ends: whether `line` is blank.
fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c == '\n') return true;
        if (!ctype.isSpace(c)) return false;
    }
    return true;
}

fn nextLine(buf: []const u8, at: usize) usize {
    return if (std.mem.findScalarPos(u8, buf, at, '\n')) |nl| nl + 1 else buf.len;
}

/// How a repository reads trailers: its `trailer.*` settings, with its
/// comment string (`#` for `auto`). Everything is `arena`'s.
pub fn trailerSettings(arena: Allocator, config: *const config_mod.Config) (Allocator.Error || error{InvalidCommentString})!trailer.Settings {
    return trailer.Settings.load(arena, config, (try Comment.read(config)).text());
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
    const line = try gpa.print("Signed-off-by: {s} <{s}>\n", .{ who.name, who.email });
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
    const end = std.mem.findScalar(u8, from, '\n') orelse from.len;
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
        while (line.len > 0 and ctype.isSpace(line[line.len - 1])) line = line[0 .. line.len - 1];
        if (line.len == 0) break;
        if (out.items.len != 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, line);
        at = next;
    }
    return out.toOwnedSlice(gpa);
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
    try shakedown.check(std.testing.allocator, {}, fuzzMessage, .{});
}

fn fuzzMessage(_: void, case: *shakedown.Case) anyerror!void {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const text = buf[0..shakedown.gen.intRange(case.source, usize, 0, buf.len)];
    case.source.bytes(text);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const block = try trailer.block(arena_state.allocator(), .{}, text, .{ .no_divider = true });
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
    // Any bytes choose a candidate or run out of them; a choice begins no
    // line of the message before its trailing comments.
    if (Comment.forMessage(.auto, text)) |chosen| {
        try std.testing.expectEqual(@as(usize, 1), chosen.len);
    } else |err| try std.testing.expectEqual(error.NoCommentCharacter, err);
}

/// All errors reported by this namespace.
pub const Error = Allocator.Error || error{ InvalidCleanupMode, InvalidCommentString, NoCommentCharacter };
