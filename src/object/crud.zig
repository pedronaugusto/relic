//! What git's `ident.c` strips from a name and an email before it writes
//! an ident: `crud` at either end, and the line's delimiters inside. One
//! table, which `Signature.write` and the identity a commit is given both
//! read.

const std = @import("std");
const Io = std.Io;

/// git's `crud`: a control byte or a space, or one of `,:;<>"\'`.
pub fn crud(c: u8) bool {
    return c <= 32 or c == ',' or c == ':' or c == ';' or c == '<' or c == '>' or c == '"' or c == '\\' or c == '\'';
}

/// `text` as git's `strbuf_addstr_without_crud` takes it, a C string, so
/// up to its first NUL, with the crud at either end cut away.
pub fn trimmed(text: []const u8) []const u8 {
    const string = text[0 .. std.mem.findScalar(u8, text, 0) orelse text.len];
    var start: usize = 0;
    while (start < string.len and crud(string[start])) start += 1;
    var end = string.len;
    while (end > start and crud(string[end - 1])) end -= 1;
    return string[start..end];
}

/// The delimiters of an ident line, which git leaves out of a name or an
/// email wherever they are.
pub const delimiters = "\n<>";

/// `text`, `trimmed` already, written without its delimiters.
pub fn writeWithout(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    var rest = text;
    while (std.mem.findAny(u8, rest, delimiters)) |at| {
        try w.writeAll(rest[0..at]);
        rest = rest[at + 1 ..];
    }
    try w.writeAll(rest);
}

test "crud is cut from the ends, up to the first NUL, and the delimiters from inside" {
    try std.testing.expectEqualStrings("A, B", trimmed(" \t,A, B;'\"\\"));
    try std.testing.expectEqualStrings("", trimmed(" ,:; <>"));
    try std.testing.expectEqualStrings("a", trimmed("a\x00b"));
    try std.testing.expectEqualStrings("\xc3\xa9", trimmed(" \xc3\xa9 "));
    var buffer: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeWithout(&w, "a<b>c\nd");
    try std.testing.expectEqualStrings("abcd", w.buffered());
}
