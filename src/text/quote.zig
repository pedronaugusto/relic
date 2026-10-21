//! git's shell single-quoting (`quote.c`), one copy for every state file
//! and command line that holds it: `author-script`, `sequencer/opts`,
//! `BISECT_NAMES`, `GIT_CONFIG_PARAMETERS`, `am`'s saved options.

const ErrorNamespace = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ctype = @import("ctype.zig");

/// All errors reported by this namespace.
pub const Error = Allocator.Error;

/// The characters git writes outside the quotes, backslashed: a quote, and
/// `!`, which some shells expand even inside them.
fn needsBackslash(c: u8) bool {
    return c == '\'' or c == '!';
}

/// git's `sq_quote_buf`: `text` single-quoted, appended to `out`.
pub fn sq(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.append(gpa, '\'');
    for (text) |c| {
        if (needsBackslash(c)) {
            try out.appendSlice(gpa, "'\\");
            try out.append(gpa, c);
            try out.append(gpa, '\'');
        } else try out.append(gpa, c);
    }
    try out.append(gpa, '\'');
}

/// One word `sqDequoteStep` read.
pub const Step = struct {
    /// The word, without its quotes.
    word: []u8,
    /// Where the text goes on after the word; `null` at its end.
    next: ?usize,
};

/// git's `sq_dequote_step`: the single-quoted word at `start`, `'\''` and
/// `'\!'` inside it read as the character, or `null` when there is none or
/// it does not end. The word is allocated in `arena`, at its exact length.
pub fn sqDequoteStep(arena: Allocator, text: []const u8, start: usize) Allocator.Error!?Step {
    const found = scan(text, start, null) orelse return null;
    const word = try arena.alloc(u8, found.len);
    _ = scan(text, start, word);
    return .{ .word = word, .next = found.next };
}

const Scanned = struct { len: usize, next: ?usize };

/// One pass over the word at `start`: its length and where the text goes
/// on, writing the word into `out` when there is one.
fn scan(text: []const u8, start: usize, out: ?[]u8) ?Scanned {
    if (start >= text.len or text[start] != '\'') return null;
    var n: usize = 0;
    var i = start + 1;
    while (true) {
        if (i >= text.len) return null;
        const c = text[i];
        i += 1;
        if (c != '\'') {
            if (out) |o| o[n] = c;
            n += 1;
            continue;
        }
        // Out of the quotes: the end, a backslashed character the quotes
        // resume after, or the word's end with more text after it.
        if (i >= text.len) return .{ .len = n, .next = null };
        if (text[i] == '\\' and i + 2 < text.len and needsBackslash(text[i + 1]) and text[i + 2] == '\'') {
            if (out) |o| o[n] = text[i + 1];
            n += 1;
            i += 3;
            continue;
        }
        return .{ .len = n, .next = i };
    }
}

/// git's `sq_dequote`: `text` as one single-quoted word and nothing after
/// it, or `null`.
pub fn sqDequote(arena: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    const step = (try sqDequoteStep(arena, text, 0)) orelse return null;
    if (step.next != null) return null;
    return step.word;
}

/// git's `sq_dequote_to_strvec`: words, each single-quoted, separated by
/// git's spaces; `null` for text that does not dequote. Empty text is no
/// words.
pub fn sqDequoteWords(arena: Allocator, text: []const u8) Allocator.Error!?[]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    if (text.len == 0) return words.items;
    var at: usize = 0;
    while (true) {
        const step = (try sqDequoteStep(arena, text, at)) orelse return null;
        try words.append(arena, step.word);
        var next = step.next orelse return words.items;
        if (!ctype.isSpace(text[next])) return null;
        while (next < text.len and ctype.isSpace(text[next])) next += 1;
        // Spaces at the end leave an empty word to read, which git refuses.
        at = next;
    }
}

test "single quotes round trip, a quote and a bang backslashed outside them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try sq(a, &out, "it's here!");
    try std.testing.expectEqualStrings("'it'\\''s here'\\!''", out.items);
    try std.testing.expectEqualStrings("it's here!", (try sqDequote(a, out.items)).?);
    try std.testing.expect(try sqDequote(a, "'a' 'b'") == null);
    try std.testing.expect(try sqDequote(a, "'open") == null);
    const words = (try sqDequoteWords(a, "'a' \t'b c'")).?;
    try std.testing.expectEqual(@as(usize, 2), words.len);
    try std.testing.expectEqualStrings("b c", words[1]);
    try std.testing.expect(try sqDequoteWords(a, "'a''b'") == null);
}

/// git's `split_cmdline`: words split at unquoted whitespace (each run of
/// it one break, so leading or trailing whitespace makes an empty word),
/// `'` and `"` quoting, and a backslash taking the next character literally
/// outside single quotes. `null` for a quote left open or a backslash at
/// the end, which git refuses. The words and the slice are `arena`'s.
pub fn splitCmdline(arena: Allocator, line: []const u8) Allocator.Error!?[]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var quoted: u8 = 0;
    var at: usize = 0;
    while (at < line.len) {
        const c = line[at];
        if (quoted == 0 and ctype.isSpace(c)) {
            try words.append(arena, try word.toOwnedSlice(arena));
            at += 1;
            while (at < line.len and ctype.isSpace(line[at])) at += 1;
        } else if (quoted == 0 and (c == '\'' or c == '"')) {
            quoted = c;
            at += 1;
        } else if (c == quoted) {
            quoted = 0;
            at += 1;
        } else {
            var ch = c;
            if (c == '\\' and quoted != '\'') {
                at += 1;
                if (at == line.len) return null;
                ch = line[at];
            }
            try word.append(arena, ch);
            at += 1;
        }
    }
    if (quoted != 0) return null;
    try words.append(arena, try word.toOwnedSlice(arena));
    return words.items;
}
