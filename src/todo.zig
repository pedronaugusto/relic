//! The instruction sheet a cherry-pick sequence and a rebase work through:
//! `.git/sequencer/todo` and `.git/rebase-merge/git-rebase-todo`.
//!
//! A sheet is written by git or by this package and read by the other, and a
//! person may have edited it in between, so it is read exactly as git reads
//! it: one instruction per line, leading blanks ignored, a carriage return
//! before the newline dropped, a command by its name or its one-letter
//! abbreviation, and a commit by anything that names one -- a full object
//! name, a unique prefix, a ref. What the line says after the commit is kept
//! as it was, because git writes it back. A sheet is written as git writes
//! it, with full object names or short ones.

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("hash.zig");
const safepath = @import("safepath.zig");

const Oid = hash.Oid;

/// An instruction, in git's order.
pub const Command = enum {
    pick,
    revert,
    edit,
    reword,
    fixup,
    squash,
    exec,
    @"break",
    label,
    reset,
    merge,
    update_ref,
    noop,
    drop,
    /// A comment or a blank line, which is kept and does nothing.
    comment,

    /// The name git writes.
    pub fn name(c: Command) []const u8 {
        return switch (c) {
            .update_ref => "update-ref",
            .comment => "#",
            else => @tagName(c),
        };
    }

    /// The one-letter abbreviation, where there is one.
    pub fn letter(c: Command) ?u8 {
        return switch (c) {
            .pick => 'p',
            .edit => 'e',
            .reword => 'r',
            .fixup => 'f',
            .squash => 's',
            .exec => 'x',
            .@"break" => 'b',
            .label => 'l',
            .reset => 't',
            .merge => 'm',
            .update_ref => 'u',
            .drop => 'd',
            .revert, .noop, .comment => null,
        };
    }

    /// Whether the instruction folds a commit into the one before it.
    pub fn isFixup(c: Command) bool {
        return c == .fixup or c == .squash;
    }

    /// Whether it does nothing but is counted: `noop`, `drop` and comments.
    pub fn isNoop(c: Command) bool {
        return c == .noop or c == .drop or c == .comment;
    }

    /// Whether it names a commit to apply.
    pub fn picksCommit(c: Command) bool {
        return @intFromEnum(c) <= @intFromEnum(Command.squash);
    }
};

/// One instruction.
pub const Item = struct {
    command: Command,
    /// The commit it names, where it names one.
    commit: ?Oid = null,
    /// `fixup -C`: keep this commit's message instead of the one before.
    replace_message: bool = false,
    /// `fixup -c` and `merge -c`: the message is to be edited.
    edit_message: bool = false,
    /// What follows the commit, or the whole argument of an instruction
    /// that names none: a subject, a label, a ref, a command line. For a
    /// comment, the whole line. Borrowed from the list.
    arg: []const u8 = "",
};

/// A parsed sheet. Every slice in it is the list's.
pub const List = struct {
    gpa: Allocator,
    /// The bytes the items' arguments point into.
    buf: []u8,
    items: std.ArrayList(Item),

    /// Release the list.
    pub fn deinit(list: *List) void {
        list.items.deinit(list.gpa);
        list.gpa.free(list.buf);
        list.* = undefined;
    }

    /// How many instructions there are, comments not counted.
    pub fn count(list: *const List) usize {
        var n: usize = 0;
        for (list.items.items) |item| {
            if (item.command != .comment) n += 1;
        }
        return n;
    }
};

/// Errors from reading a sheet.
pub const ParseError = error{
    /// A line that is not an instruction. `Diagnostic` says which.
    InvalidTodoLine,
    /// A `fixup` or `squash` with nothing before it to fold into.
    FixupWithoutCommit,
} || Allocator.Error;

/// What was wrong, when parsing failed.
pub const Diagnostic = struct {
    /// One-based.
    line: usize = 0,
    reason: Reason = .unknown_command,

    pub const Reason = enum {
        unknown_command,
        unexpected_argument,
        missing_argument,
        unknown_commit,
        invalid_label,
        invalid_ref,
        merge_commit,
        fixup_first,
    };
};

/// How a sheet's commits are found: whatever names a commit -- a full or
/// abbreviated object name, a ref -- to the commit, and how many parents it
/// has. `null` when the name names no commit.
pub const Resolver = struct {
    context: *anyopaque,
    resolveFn: *const fn (context: *anyopaque, text: []const u8) ?Resolved,

    pub const Resolved = struct { oid: Oid, parents: usize };

    fn resolve(r: Resolver, text: []const u8) ?Resolved {
        return r.resolveFn(r.context, text);
    }
};

/// How a sheet is read.
pub const ParseOptions = struct {
    /// The comment string, `core.commentChar`.
    comment: []const u8 = "#",
    /// A rebase refuses a merge commit anywhere but `merge` and `drop`.
    rebase: bool = false,
    /// Whether a `fixup` may be the first instruction, which it may when
    /// some have already been done.
    fixup_first_ok: bool = false,
    diagnostic: ?*Diagnostic = null,
};

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn skipBlanks(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and isBlank(text[i])) i += 1;
    return text[i..];
}

/// Whether `line` begins with `command` by name or by letter, followed by
/// the end of the line or a blank; the rest when it does.
fn matchCommand(command: Command, line: []const u8) ?[]const u8 {
    const word = command.name();
    var rest: ?[]const u8 = null;
    if (std.mem.startsWith(u8, line, word)) {
        rest = line[word.len..];
    } else if (command.letter()) |c| {
        if (line.len != 0 and line[0] == c) rest = line[1..];
    }
    const after = rest orelse return null;
    if (after.len == 0 or after[0] == ' ' or after[0] == '\t' or after[0] == '\n' or after[0] == '\r') return after;
    return null;
}

fn fail(options: ParseOptions, line: usize, reason: Diagnostic.Reason) ParseError {
    if (options.diagnostic) |d| d.* = .{ .line = line, .reason = reason };
    return error.InvalidTodoLine;
}

/// A label git accepts: a ref name, one level allowed, that is not `#`,
/// which a `merge` line uses to separate its parents from its subject.
pub fn isValidLabel(text: []const u8) bool {
    if (std.mem.eql(u8, text, "#")) return false;
    return safepath.isValidRefName(text);
}

/// Parse one line, which has had its newline and a carriage return before
/// it removed.
fn parseLine(line_in: []const u8, number: usize, resolver: Resolver, options: ParseOptions) ParseError!Item {
    const line = skipBlanks(line_in);
    if (line.len == 0 or line[0] == '\r' or std.mem.startsWith(u8, line, options.comment)) {
        return .{ .command = .comment, .arg = line };
    }
    var command: ?Command = null;
    var rest: []const u8 = undefined;
    inline for (std.meta.fields(Command)) |field| {
        const c: Command = @enumFromInt(field.value);
        if (command == null and c != .comment) {
            if (matchCommand(c, line)) |after| {
                command = c;
                rest = after;
            }
        }
    }
    const cmd = command orelse return fail(options, number, .unknown_command);
    const padded = rest.len != skipBlanks(rest).len;
    rest = skipBlanks(rest);

    if (cmd == .noop or cmd == .@"break") {
        if (rest.len != 0) return fail(options, number, .unexpected_argument);
        return .{ .command = cmd, .arg = rest };
    }
    if (!padded) return fail(options, number, .missing_argument);

    switch (cmd) {
        .exec, .reset => return .{ .command = cmd, .arg = rest },
        .label => {
            if (!isValidLabel(rest)) return fail(options, number, .invalid_label);
            return .{ .command = cmd, .arg = rest };
        },
        .update_ref => {
            // A full ref name: more than one level.
            if (!safepath.isValidRefName(rest) or std.mem.indexOfScalar(u8, rest, '/') == null) {
                return fail(options, number, .invalid_ref);
            }
            return .{ .command = cmd, .arg = rest };
        },
        else => {},
    }

    var item: Item = .{ .command = cmd };
    if (cmd == .fixup) {
        if (std.mem.startsWith(u8, rest, "-C")) {
            rest = skipBlanks(rest[2..]);
            item.replace_message = true;
        } else if (std.mem.startsWith(u8, rest, "-c")) {
            rest = skipBlanks(rest[2..]);
            item.edit_message = true;
        }
    }
    if (cmd == .merge) {
        if (std.mem.startsWith(u8, rest, "-C")) {
            rest = skipBlanks(rest[2..]);
        } else if (std.mem.startsWith(u8, rest, "-c")) {
            rest = skipBlanks(rest[2..]);
            item.edit_message = true;
        } else {
            item.edit_message = true;
            item.arg = rest;
            return item;
        }
    }

    const end = std.mem.indexOfAny(u8, rest, " \t\n") orelse rest.len;
    const named = rest[0..end];
    item.arg = skipBlanks(rest[end..]);
    const resolved = resolver.resolve(named) orelse return fail(options, number, .unknown_commit);
    item.commit = resolved.oid;
    if (options.rebase and resolved.parents > 1 and cmd != .merge and cmd != .drop) {
        return fail(options, number, .merge_commit);
    }
    return item;
}

/// Parse a sheet. `bytes` is copied; the list owns what its items borrow.
pub fn parse(gpa: Allocator, bytes: []const u8, resolver: Resolver, options: ParseOptions) ParseError!List {
    const buf = try gpa.dupe(u8, bytes);
    errdefer gpa.free(buf);
    var items: std.ArrayList(Item) = .empty;
    errdefer items.deinit(gpa);

    var fixup_ok = options.fixup_first_ok;
    var at: usize = 0;
    var number: usize = 1;
    while (at < buf.len) : (number += 1) {
        const nl = std.mem.indexOfScalarPos(u8, buf, at, '\n');
        var line = buf[at .. nl orelse buf.len];
        at = if (nl) |n| n + 1 else buf.len;
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const item = try parseLine(line, number, resolver, options);
        if (!fixup_ok) {
            if (item.command.isFixup()) {
                if (options.diagnostic) |d| d.* = .{ .line = number, .reason = .fixup_first };
                return error.FixupWithoutCommit;
            }
            if (!item.command.isNoop()) fixup_ok = true;
        }
        try items.append(gpa, item);
    }
    return .{ .gpa = gpa, .buf = buf, .items = items };
}

/// How a sheet is written.
pub const FormatOptions = struct {
    /// `rebase.abbreviateCommands`: `p` for `pick` and so on.
    abbreviate_commands: bool = false,
    /// Short object names instead of full ones, as git writes the sheet a
    /// person edits and the sequencer's `todo`.
    short: ?Shortener = null,
};

/// Turns an object name into the short name git would print.
pub const Shortener = struct {
    context: *anyopaque,
    shortenFn: *const fn (context: *anyopaque, oid: Oid, buf: *[hash.max_hex_len]u8) []const u8,
};

/// Write `items` as git's `todo_list_to_strbuf` writes them.
pub fn format(w: *std.Io.Writer, items: []const Item, options: FormatOptions) std.Io.Writer.Error!void {
    for (items) |item| try formatItem(w, item, options);
}

/// Write one instruction and its newline.
pub fn formatItem(w: *std.Io.Writer, item: Item, options: FormatOptions) std.Io.Writer.Error!void {
    if (item.command == .comment) {
        try w.writeAll(item.arg);
        try w.writeByte('\n');
        return;
    }
    if (options.abbreviate_commands) {
        if (item.command.letter()) |c| try w.writeByte(c) else try w.writeAll(item.command.name());
    } else try w.writeAll(item.command.name());
    if (item.commit) |oid| {
        if (item.command == .fixup) {
            if (item.edit_message) try w.writeAll(" -c") else if (item.replace_message) try w.writeAll(" -C");
        }
        if (item.command == .merge) {
            try w.writeAll(if (item.edit_message) " -c" else " -C");
        }
        var buf: [hash.max_hex_len]u8 = undefined;
        const text = if (options.short) |s| s.shortenFn(s.context, oid, &buf) else oid.hex(&buf);
        try w.writeByte(' ');
        try w.writeAll(text);
    }
    if (item.arg.len != 0) {
        try w.writeByte(' ');
        try w.writeAll(item.arg);
    }
    try w.writeByte('\n');
}

/// Write `items` to a new buffer. The result is the caller's.
pub fn toBytes(gpa: Allocator, items: []const Item, options: FormatOptions) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    format(&out.writer, items, options) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// The help git writes after the instructions of a sheet a person is given
/// to edit, with the `Rebase <range> onto <onto> (<n> commands)` line first.
pub fn writeHelp(w: *std.Io.Writer, command_count: usize, revisions: []const u8, onto: []const u8, comment: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('\n');
    try w.print("{s} Rebase {s} onto {s} ({d} command{s})\n", .{
        comment, revisions, onto, command_count, if (command_count == 1) "" else "s",
    });
    const help =
        \\
        \\Commands:
        \\p, pick <commit> = use commit
        \\r, reword <commit> = use commit, but edit the commit message
        \\e, edit <commit> = use commit, but stop for amending
        \\s, squash <commit> = use commit, but meld into previous commit
        \\f, fixup [-C | -c] <commit> = like "squash" but keep only the previous
        \\                   commit's log message, unless -C is used, in which case
        \\                   keep only this commit's message; -c is same as -C but
        \\                   opens the editor
        \\x, exec <command> = run command (the rest of the line) using shell
        \\b, break = stop here (continue rebase later with 'git rebase --continue')
        \\d, drop <commit> = remove commit
        \\l, label <label> = label current HEAD with a name
        \\t, reset <label> = reset HEAD to a label
        \\m, merge [-C <commit> | -c <commit>] <label> [# <oneline>]
        \\        create a merge commit using the original merge commit's
        \\        message (or the oneline, if no original merge commit was
        \\        specified); use -c <commit> to reword the commit message
        \\u, update-ref <ref> = track a placeholder for the <ref> to be updated
        \\                      to this position in the new commits. The <ref> is
        \\                      updated at the end of the rebase
        \\
        \\These lines can be re-ordered; they are executed from top to bottom.
        \\
        \\If you remove a line here THAT COMMIT WILL BE LOST.
        \\
        \\However, if you remove everything, the rebase will be aborted.
        \\
        \\
    ;
    try writeCommented(w, help, comment);
}

/// `strbuf_add_commented_lines`: each line after the comment string, a
/// space between them unless the line is empty or starts with a tab.
pub fn writeCommented(w: *std.Io.Writer, text: []const u8, comment: []const u8) std.Io.Writer.Error!void {
    var at: usize = 0;
    while (at < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, at, '\n');
        const line = text[at .. nl orelse text.len];
        at = if (nl) |n| n + 1 else text.len;
        try w.writeAll(comment);
        if (line.len != 0 and line[0] != '\t') try w.writeByte(' ');
        try w.writeAll(line);
        try w.writeByte('\n');
    }
}

//=========================================================================
// Tests
//=========================================================================

const TestResolver = struct {
    fn resolve(_: *anyopaque, text: []const u8) ?Resolver.Resolved {
        if (text.len < 4 or text.len > 40) return null;
        for (text) |c| if (!std.ascii.isHex(c)) return null;
        var full: [40]u8 = @splat('0');
        @memcpy(full[0..text.len], text);
        const oid = Oid.parse(.sha1, &full) catch return null;
        return .{ .oid = oid, .parents = if (text[0] == 'f') 2 else 1 };
    }
    fn shorten(_: *anyopaque, oid: Oid, buf: *[hash.max_hex_len]u8) []const u8 {
        return oid.hex(buf)[0..7];
    }
};

var test_context: u8 = 0;
const test_resolver: Resolver = .{ .context = &test_context, .resolveFn = TestResolver.resolve };

test "every instruction reads and writes back as git writes it" {
    const gpa = std.testing.allocator;
    const sheet =
        "pick 1234567 one\n" ++
        "p 2345678 # two\n" ++
        "  reword 3456789\n" ++
        "e 4567890 edit me\r\n" ++
        "squash 5678901 five\n" ++
        "f -C 6789012 six\n" ++
        "fixup -c 7890123 seven\n" ++
        "x make test\n" ++
        "break\n" ++
        "l onto\n" ++
        "t onto\n" ++
        "merge -C 8901234 topic # Merge topic\n" ++
        "m -c 9012345 other\n" ++
        "merge third\n" ++
        "u refs/heads/side\n" ++
        "noop\n" ++
        "d abcdef0\n" ++
        "# a comment\n" ++
        "\n";
    var list = try parse(gpa, sheet, test_resolver, .{});
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 19), list.items.items.len);
    try std.testing.expectEqual(@as(usize, 17), list.count());
    const written = try toBytes(gpa, list.items.items, .{ .short = .{ .context = &test_context, .shortenFn = TestResolver.shorten } });
    defer gpa.free(written);
    try std.testing.expectEqualStrings(
        "pick 1234567 one\n" ++
            "pick 2345678 # two\n" ++
            "reword 3456789\n" ++
            "edit 4567890 edit me\n" ++
            "squash 5678901 five\n" ++
            "fixup -C 6789012 six\n" ++
            "fixup -c 7890123 seven\n" ++
            "exec make test\n" ++
            "break\n" ++
            "label onto\n" ++
            "reset onto\n" ++
            "merge -C 8901234 topic # Merge topic\n" ++
            "merge -c 9012345 other\n" ++
            "merge third\n" ++
            "update-ref refs/heads/side\n" ++
            "noop\n" ++
            "drop abcdef0\n" ++
            "# a comment\n" ++
            "\n",
        written,
    );
    const abbreviated = try toBytes(gpa, list.items.items[0..3], .{ .abbreviate_commands = true });
    defer gpa.free(abbreviated);
    try std.testing.expectEqualStrings(
        "p 1234567000000000000000000000000000000000 one\n" ++
            "p 2345678000000000000000000000000000000000 # two\n" ++
            "r 3456789000000000000000000000000000000000\n",
        abbreviated,
    );
}

test "a bad line is refused with its number and why" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { sheet: []const u8, line: usize, reason: Diagnostic.Reason }{
        .{ .sheet = "pick 1234567\nfrobnicate 1234567\n", .line = 2, .reason = .unknown_command },
        .{ .sheet = "break now\n", .line = 1, .reason = .unexpected_argument },
        .{ .sheet = "pick\n", .line = 1, .reason = .missing_argument },
        .{ .sheet = "pick zzzz\n", .line = 1, .reason = .unknown_commit },
        .{ .sheet = "label #\n", .line = 1, .reason = .invalid_label },
        .{ .sheet = "update-ref main\n", .line = 1, .reason = .invalid_ref },
    };
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidTodoLine, parse(gpa, case.sheet, test_resolver, .{ .diagnostic = &diagnostic }));
        try std.testing.expectEqual(case.line, diagnostic.line);
        try std.testing.expectEqual(case.reason, diagnostic.reason);
    }
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidTodoLine, parse(gpa, "pick f123456\n", test_resolver, .{ .rebase = true, .diagnostic = &diagnostic }));
    try std.testing.expectEqual(Diagnostic.Reason.merge_commit, diagnostic.reason);
    try std.testing.expectError(error.FixupWithoutCommit, parse(gpa, "# c\nfixup 1234567\n", test_resolver, .{}));
    var ok = try parse(gpa, "fixup 1234567\n", test_resolver, .{ .fixup_first_ok = true });
    ok.deinit();
}

test "fuzz: any bytes are a sheet or a named error, and a sheet writes back to one that reads the same" {
    try std.testing.fuzz({}, fuzzTodo, .{});
}

fn fuzzTodo(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var buf: [512]u8 = undefined;
    const text = buf[0..smith.slice(&buf)];
    var list = parse(gpa, text, test_resolver, .{ .fixup_first_ok = true }) catch |err| switch (err) {
        error.InvalidTodoLine, error.FixupWithoutCommit => return,
        error.OutOfMemory => return err,
    };
    defer list.deinit();
    const written = try toBytes(gpa, list.items.items, .{});
    defer gpa.free(written);
    var again = try parse(gpa, written, test_resolver, .{ .fixup_first_ok = true });
    defer again.deinit();
    try std.testing.expectEqual(list.items.items.len, again.items.items.len);
    for (list.items.items, again.items.items) |a, b| {
        try std.testing.expectEqual(a.command, b.command);
        try std.testing.expectEqual(a.commit, b.commit);
    }
}
