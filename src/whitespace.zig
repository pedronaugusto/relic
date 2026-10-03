//! git's whitespace rules: what `core.whitespace` and the `whitespace`
//! attribute name, what counts as an error under them, and how a line is
//! fixed. This is git's `ws.c`; `git apply --whitespace` and `git diff
//! --check` read lines through it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A rule set: the bits below and, in the low six bits, the tab width.
pub const Rule = u32;

pub const blank_at_eol: Rule = 1 << 6;
pub const space_before_tab: Rule = 1 << 7;
pub const indent_with_non_tab: Rule = 1 << 8;
pub const cr_at_eol: Rule = 1 << 9;
pub const blank_at_eof: Rule = 1 << 10;
pub const tab_in_indent: Rule = 1 << 11;
pub const incomplete_line: Rule = 1 << 12;
/// `trailing-space`: both of the first.
pub const trailing_space: Rule = blank_at_eol | blank_at_eof;
pub const tab_width_mask: Rule = (1 << 6) - 1;
/// What a repository with no `core.whitespace` uses.
pub const default_rule: Rule = trailing_space | space_before_tab | 8;

/// The tab width a rule set carries.
pub fn tabWidth(rule: Rule) u32 {
    return rule & tab_width_mask;
}

const Name = struct { name: []const u8, bits: Rule, loosens_error: bool = false, exclude_default: bool = false };

const names = [_]Name{
    .{ .name = "trailing-space", .bits = trailing_space },
    .{ .name = "space-before-tab", .bits = space_before_tab },
    .{ .name = "indent-with-non-tab", .bits = indent_with_non_tab },
    .{ .name = "cr-at-eol", .bits = cr_at_eol, .loosens_error = true },
    .{ .name = "blank-at-eol", .bits = blank_at_eol },
    .{ .name = "blank-at-eof", .bits = blank_at_eof },
    .{ .name = "tab-in-indent", .bits = tab_in_indent, .exclude_default = true },
    .{ .name = "incomplete-line", .bits = incomplete_line },
};

/// Errors from reading a rule list.
pub const ParseError = error{
    /// `tab-in-indent` and `indent-with-non-tab` together, which git
    /// refuses because no line could satisfy both.
    ConflictingWhitespaceRules,
};

/// A `core.whitespace` value or a `whitespace=` attribute value: comma
/// separated names, each optionally negated with `-`, and `tabwidth=<n>`,
/// on top of the default. A name git does not know is passed over, as git
/// passes over it; so is a tab width outside 1 to 63.
pub fn parse(text: []const u8) ParseError!Rule {
    var rule = default_rule;
    var rest = text;
    while (true) {
        var start: usize = 0;
        while (start < rest.len and (rest[start] == ',' or rest[start] == ' ' or rest[start] == '\t' or rest[start] == '\n' or rest[start] == '\r')) start += 1;
        rest = rest[start..];
        const ep = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        var word = rest[0..ep];
        var negated = false;
        if (word.len > 0 and word[0] == '-') {
            negated = true;
            word = word[1..];
        }
        if (word.len == 0) break;
        for (names) |n| {
            // git compares the first `len` bytes of the name, so a prefix
            // of a name names it
            if (word.len > n.name.len or !std.mem.eql(u8, n.name[0..word.len], word)) continue;
            if (negated) rule &= ~n.bits else rule |= n.bits;
            break;
        }
        if (std.mem.startsWith(u8, word, "tabwidth=")) {
            const width = std.fmt.parseInt(u32, leadingDigits(word["tabwidth=".len..]), 10) catch 0;
            if (width > 0 and width < 0o100) {
                rule &= ~tab_width_mask;
                rule |= width;
            }
        }
        if (ep >= rest.len) break;
        rest = rest[ep..];
    }
    if (rule & tab_in_indent != 0 and rule & indent_with_non_tab != 0) return error.ConflictingWhitespaceRules;
    return rule;
}

fn leadingDigits(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    return s[0..i];
}

/// What the `whitespace` attribute says for a path.
pub const Attribute = union(enum) {
    /// Not mentioned, or `!whitespace`: the configured rule.
    unspecified,
    /// `whitespace`: every rule that is not a loosening and not off by
    /// default.
    set,
    /// `-whitespace`: none.
    unset,
    /// `whitespace=<rules>`.
    value: []const u8,
};

/// The rule a path is checked by, from its attribute and the configured
/// rule (`core.whitespace`, or `default_rule`).
pub fn forAttribute(attribute: Attribute, configured: Rule) ParseError!Rule {
    return switch (attribute) {
        .unspecified => configured,
        .unset => tabWidth(configured),
        .set => blk: {
            var all = tabWidth(configured);
            for (names) |n| {
                if (!n.loosens_error and !n.exclude_default) all |= n.bits;
            }
            break :blk all;
        },
        .value => |v| parse(v),
    };
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

/// The errors `line` has under `rule`: a set of the bits above. `line`
/// includes its newline, if it has one.
pub fn check(line_in: []const u8, rule: Rule) Rule {
    var result: Rule = 0;
    var len = line_in.len;
    const line = line_in;
    var trailing_newline = false;
    if (len > 0 and line[len - 1] == '\n') {
        trailing_newline = true;
        len -= 1;
    }
    if (rule & cr_at_eol != 0 and len > 0 and line[len - 1] == '\r') len -= 1;
    var trailing_whitespace: usize = len;
    if (rule & blank_at_eol != 0) {
        var i = len;
        while (i > 0) {
            i -= 1;
            if (isSpace(line[i])) {
                trailing_whitespace = i;
                result |= blank_at_eol;
            } else break;
        }
    }
    if (!trailing_newline and rule & incomplete_line != 0) result |= incomplete_line;
    var written: usize = 0;
    var i: usize = 0;
    while (i < trailing_whitespace) : (i += 1) {
        if (line[i] == ' ') continue;
        if (line[i] != '\t') break;
        if (rule & space_before_tab != 0 and written < i) {
            result |= space_before_tab;
        } else if (rule & tab_in_indent != 0) {
            result |= tab_in_indent;
        }
        written = i + 1;
    }
    if (rule & indent_with_non_tab != 0 and i - written >= tabWidth(rule)) result |= indent_with_non_tab;
    return result;
}

/// git's message for a set of errors, as `apply` and `diff --check` print
/// it.
pub fn errorString(gpa: Allocator, ws: Rule) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (ws & trailing_space == trailing_space) {
        try out.appendSlice(gpa, "trailing whitespace");
    } else {
        if (ws & blank_at_eol != 0) try out.appendSlice(gpa, "trailing whitespace");
        if (ws & blank_at_eof != 0) {
            if (out.items.len != 0) try out.appendSlice(gpa, ", ");
            try out.appendSlice(gpa, "new blank line at EOF");
        }
    }
    const rest = [_]struct { bit: Rule, text: []const u8 }{
        .{ .bit = space_before_tab, .text = "space before tab in indent" },
        .{ .bit = indent_with_non_tab, .text = "indent with spaces" },
        .{ .bit = tab_in_indent, .text = "tab in indent" },
        .{ .bit = incomplete_line, .text = "no newline at the end of file" },
    };
    for (rest) |r| {
        if (ws & r.bit == 0) continue;
        if (out.items.len != 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, r.text);
    }
    return out.toOwnedSlice(gpa);
}

/// Whether the line is only whitespace.
pub fn blankLine(line: []const u8) bool {
    for (line) |c| if (!isSpace(c)) return false;
    return true;
}

/// Append `src` to `dst` with the errors `rule` names fixed: trailing
/// whitespace removed, a missing final newline added, spaces before a tab
/// and runs of spaces in the indent made tabs, or tabs in the indent made
/// spaces. Returns whether anything changed.
pub fn fixCopy(gpa: Allocator, dst: *std.ArrayList(u8), src_in: []const u8, rule: Rule) Allocator.Error!bool {
    var src = src_in;
    var len = src.len;
    var add_nl_to_tail = false;
    var add_cr_to_tail = false;
    var fixed = false;
    var last_tab_in_indent: isize = -1;
    var last_space_in_indent: isize = -1;
    var need_fix_leading_space = false;

    if (rule & incomplete_line != 0) {
        if (len > 0 and src[len - 1] != '\n') {
            fixed = true;
            add_nl_to_tail = true;
        }
    }
    if (rule & blank_at_eol != 0) {
        if (len > 0 and src[len - 1] == '\n') {
            add_nl_to_tail = true;
            len -= 1;
            if (len > 0 and src[len - 1] == '\r') {
                add_cr_to_tail = rule & cr_at_eol != 0;
                len -= 1;
            }
        }
        if (len > 0 and isSpace(src[len - 1])) {
            while (len > 0 and isSpace(src[len - 1])) len -= 1;
            fixed = true;
        }
    }
    const tw: isize = @intCast(tabWidth(rule));
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const ch = src[i];
        if (ch == '\t') {
            last_tab_in_indent = @intCast(i);
            if (rule & space_before_tab != 0 and last_space_in_indent >= 0) need_fix_leading_space = true;
        } else if (ch == ' ') {
            last_space_in_indent = @intCast(i);
            if (rule & indent_with_non_tab != 0 and tw <= @as(isize, @intCast(i)) - last_tab_in_indent) need_fix_leading_space = true;
        } else break;
    }
    if (need_fix_leading_space) {
        var consecutive_spaces: isize = 0;
        var last: usize = @intCast(last_tab_in_indent + 1);
        if (rule & indent_with_non_tab != 0) {
            last = if (last_tab_in_indent < last_space_in_indent) @intCast(last_space_in_indent + 1) else @intCast(last_tab_in_indent + 1);
        }
        for (src[0..last]) |ch| {
            if (ch != ' ') {
                consecutive_spaces = 0;
                try dst.append(gpa, ch);
            } else {
                consecutive_spaces += 1;
                if (consecutive_spaces == tw) {
                    try dst.append(gpa, '\t');
                    consecutive_spaces = 0;
                }
            }
        }
        while (consecutive_spaces > 0) : (consecutive_spaces -= 1) try dst.append(gpa, ' ');
        len -= last;
        src = src[last..];
        fixed = true;
    } else if (rule & tab_in_indent != 0 and last_tab_in_indent >= 0) {
        const start = dst.items.len;
        const last: usize = @intCast(last_tab_in_indent + 1);
        for (src[0..last]) |ch| {
            if (ch == '\t') {
                // git's do-while: at least one space, then up to the stop
                try dst.append(gpa, ' ');
                while ((dst.items.len - start) % @as(usize, @intCast(tw)) != 0) try dst.append(gpa, ' ');
            } else try dst.append(gpa, ch);
        }
        len -= last;
        src = src[last..];
        fixed = true;
    }
    try dst.appendSlice(gpa, src[0..len]);
    if (add_cr_to_tail) try dst.append(gpa, '\r');
    if (add_nl_to_tail) try dst.append(gpa, '\n');
    return fixed;
}

test "rules parse as git's do and errors are found and fixed" {
    try std.testing.expectEqual(default_rule, try parse(""));
    try std.testing.expectEqual(default_rule | indent_with_non_tab, try parse("indent-with-non-tab"));
    const four = try parse("tabwidth=4,-blank-at-eof");
    try std.testing.expectEqual(@as(u32, 4), tabWidth(four));
    try std.testing.expectEqual(@as(u32, 0), four & blank_at_eof);
    try std.testing.expectError(error.ConflictingWhitespaceRules, parse("tab-in-indent,indent-with-non-tab"));
    try std.testing.expectEqual(blank_at_eol, check("a  \n", default_rule));
    try std.testing.expectEqual(space_before_tab, check(" \tx\n", default_rule));
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expect(try fixCopy(gpa, &out, " \tx  \n", default_rule));
    try std.testing.expectEqualStrings("\tx\n", out.items);
    const msg = try errorString(gpa, blank_at_eol | space_before_tab);
    defer gpa.free(msg);
    try std.testing.expectEqualStrings("trailing whitespace, space before tab in indent", msg);
}
