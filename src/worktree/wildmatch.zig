//! Glob matching as git does it, not as POSIX fnmatch does it.
//!
//! `.gitignore`, `.gitattributes` and pathspecs are all matched with git's
//! `wildmatch()`, which differs from fnmatch in three ways that matter: `**`
//! is a distinct wildcard when it stands alone as a path component, a single
//! `*` refuses to cross `/`, and bracket expressions keep the quirks of the
//! original Rich Salz matcher (a `[` that does not open a valid `[:class:]`
//! stays a literal, case folding applies to the text byte but not to the
//! pattern byte behind a backslash).
//!
//! Everything here works on bytes. A pattern and a text are compared without
//! any notion of UTF-8, because git compares paths the same way, and a path in
//! a git tree is an arbitrary byte string.

const std = @import("std");

/// Flags that change what a pattern means.
pub const Options = struct {
    /// WM_PATHNAME: `*` and `?` do not match `/`, and `**` is only special
    /// as a whole path component.
    pathname: bool = true,
    /// WM_CASEFOLD: compare ASCII letters case-insensitively.
    case_fold: bool = false,
};

/// Errors from the glob matcher.
pub const Error = error{
    /// A `[` with no `]`, or a bracket expression naming an unknown class.
    InvalidPattern,
    /// The pattern nested wildcards deeper than the matcher will recurse.
    PatternTooComplex,
};

/// Whether `pattern` matches the whole of `text`.
///
/// A malformed bracket expression is only reported when matching reaches it;
/// `match("x[abc", "y", .{})` is a plain `false` because the `x` already
/// failed, which is how git behaves too.
pub fn match(pattern: []const u8, text: []const u8, options: Options) Error!bool {
    return try dowild(pattern, 0, text, 0, options, 0) == .match;
}

/// What a match attempt says, as git's `dowild` says it. The two aborts are
/// what keep backtracking linear: a failure no later placement of an outer
/// star can mend says so, and the outer stars stop trying.
const Outcome = enum {
    match,
    no_match,
    /// No placement of any star can match: the text ran out, or a literal
    /// after a star is nowhere in the rest of it.
    abort_all,
    /// No placement of a star short of a `**` can match: only a `**` that
    /// may cross a `/` is worth moving.
    abort_to_starstar,
};

/// Every star tried is one frame, so a pattern of a few hundred stars is as
/// deep as this goes; past it the pattern is refused rather than run off the
/// stack.
const max_depth = 1024;

/// git's `dowild` from `wildmatch.c`, over bytes: a star tries each place
/// the rest of the pattern could start, and gives up on the first abort.
fn dowild(
    pattern: []const u8,
    pattern_start: usize,
    text: []const u8,
    text_start: usize,
    options: Options,
    depth: u32,
) Error!Outcome {
    if (depth > max_depth) return error.PatternTooComplex;
    var p = pattern_start;
    var t = text_start;
    while (p < pattern.len) {
        if (pattern[p] != '*') {
            if (t >= text.len) return .abort_all;
            const item = try matchItem(pattern, p, text[t], options);
            if (!item.matched) return .no_match;
            p = item.next;
            t += 1;
            continue;
        }

        // A run of stars, and how far it may reach.
        var q = p + 1;
        var match_slash = !options.pathname;
        if (q < pattern.len and pattern[q] == '*') {
            while (q < pattern.len and pattern[q] == '*') q += 1;
            const starts_component = p == 0 or pattern[p - 1] == '/';
            const ends_component = q == pattern.len or pattern[q] == '/' or
                (pattern[q] == '\\' and q + 1 < pattern.len and pattern[q + 1] == '/');
            if (!options.pathname) {
                match_slash = true;
            } else if (starts_component and ends_component) {
                // `**/` may match nothing at all, slash included, which is
                // what lets `a/**/b` match `a/b`.
                if (q < pattern.len and pattern[q] == '/') {
                    if (try dowild(pattern, q + 1, text, t, options, depth + 1) == .match) return .match;
                }
                match_slash = true;
            }
        }
        p = q;

        if (p == pattern.len) {
            // A trailing `**` matches everything; a trailing `*` only what
            // has no slash left.
            if (!match_slash and std.mem.findScalarPos(u8, text, t, '/') != null) return .abort_to_starstar;
            return .match;
        }
        if (!match_slash and pattern[p] == '/') {
            // One star and a slash: the star takes the rest of this
            // component, and the slashes meet.
            const slash = std.mem.findScalarPos(u8, text, t, '/') orelse return .abort_all;
            t = slash + 1;
            p += 1;
            continue;
        }
        while (t < text.len) {
            // A literal after the star: the star takes everything before
            // its next appearance, and none appearing is the end of it.
            if (!isGlobSpecial(pattern[p])) {
                const want = if (options.case_fold) fold(pattern[p]) else pattern[p];
                while (t < text.len and (match_slash or text[t] != '/')) : (t += 1) {
                    const have = if (options.case_fold) fold(text[t]) else text[t];
                    if (have == want) break;
                }
                if (t >= text.len or (if (options.case_fold) fold(text[t]) else text[t]) != want) {
                    return if (match_slash) .abort_all else .abort_to_starstar;
                }
            }
            const matched = try dowild(pattern, p, text, t, options, depth + 1);
            if (matched != .no_match) {
                if (!match_slash or matched != .abort_to_starstar) return matched;
            } else if (!match_slash and text[t] == '/') return .abort_to_starstar;
            t += 1;
        }
        return .abort_all;
    }
    return if (t == text.len) .match else .no_match;
}

/// git's `is_glob_special`: the bytes a star cannot skip ahead to.
fn isGlobSpecial(c: u8) bool {
    return c == '*' or c == '?' or c == '[' or c == '\\';
}

const Item = struct {
    matched: bool,
    /// Index just past the pattern item, whatever its length.
    next: usize,
};

/// Matches the single pattern item at `pi` against one text byte.
fn matchItem(pattern: []const u8, pi: usize, raw: u8, options: Options) Error!Item {
    const text_byte = if (options.case_fold) fold(raw) else raw;
    switch (pattern[pi]) {
        '?' => return .{ .matched = !(options.pathname and raw == '/'), .next = pi + 1 },
        '[' => return matchBracket(pattern, pi, text_byte, options),
        '\\' => {
            // The escaped pattern byte is compared raw against the folded
            // text byte, exactly as git does it, so under WM_CASEFOLD `\b`
            // matches `B` while `\A` does not match `a`.
            //
            // A trailing lone `\` matches nothing at all: git reads the byte
            // past the end of the pattern as NUL, so an ignore line written
            // `a\` does not match a file named `a\` while `a\\` does.
            // Confirmed against git 2.55 rather than assumed.
            if (pi + 1 >= pattern.len) return .{ .matched = false, .next = pi + 1 };
            return .{ .matched = text_byte == pattern[pi + 1], .next = pi + 2 };
        },
        else => {
            const pattern_byte = if (options.case_fold) fold(pattern[pi]) else pattern[pi];
            return .{ .matched = text_byte == pattern_byte, .next = pi + 1 };
        },
    }
}

/// Matches a bracket expression starting at the `[` in `pattern[pi]`.
///
/// `text_byte` arrives already case-folded, the same way git folds the text
/// byte once before it looks at the pattern. Range ends are compared unfolded
/// against it, with a second try at the upper-case text byte, which is why
/// `[A-Z]` matches `a` under case folding but `[A]` does not.
fn matchBracket(pattern: []const u8, pi: usize, text_byte: u8, options: Options) Error!Item {
    var p = pi + 1;
    if (p >= pattern.len) return error.InvalidPattern;

    var negated = false;
    if (pattern[p] == '!' or pattern[p] == '^') {
        negated = true;
        p += 1;
    }

    var matched = false;
    // Zero means "no byte that could open a range", which is how git spells
    // it; a range end and a character class both reset it.
    var prev: u8 = 0;

    while (true) {
        if (p >= pattern.len) return error.InvalidPattern;
        var current = pattern[p];

        if (current == '\\') {
            p += 1;
            if (p >= pattern.len) return error.InvalidPattern;
            current = pattern[p];
            if (text_byte == current) matched = true;
        } else if (current == '-' and prev != 0 and p + 1 < pattern.len and pattern[p + 1] != ']') {
            p += 1;
            var high = pattern[p];
            if (high == '\\') {
                p += 1;
                if (p >= pattern.len) return error.InvalidPattern;
                high = pattern[p];
            }
            if (text_byte >= prev and text_byte <= high) {
                matched = true;
            } else if (options.case_fold and isLower(text_byte)) {
                const upper = text_byte - ('a' - 'A');
                if (upper >= prev and upper <= high) matched = true;
            }
            current = 0;
        } else if (current == '[' and p + 1 < pattern.len and pattern[p + 1] == ':') {
            const name_start = p + 2;
            var close = name_start;
            while (close < pattern.len and pattern[close] != ']') close += 1;
            if (close >= pattern.len) return error.InvalidPattern;
            if (close < name_start + 1 or pattern[close - 1] != ':') {
                // No `:]`, so the `[` is an ordinary member and scanning
                // resumes at the `:` right after it.
                if (text_byte == '[') matched = true;
            } else {
                if (try matchClass(pattern[name_start .. close - 1], text_byte, options)) matched = true;
                p = close;
                current = 0;
            }
        } else if (text_byte == current) {
            matched = true;
        }

        prev = current;
        p += 1;
        if (p < pattern.len and pattern[p] == ']') break;
    }

    // A bracket never matches a separator under WM_PATHNAME, not even `[/]`.
    const hit = (matched != negated) and !(options.pathname and text_byte == '/');
    return .{ .matched = hit, .next = p + 1 };
}

/// Whether `text_byte` belongs to the POSIX class `name`.
///
/// The classes are ASCII only: git builds them from its own table, so a byte
/// above 0x7f is in no class regardless of locale.
fn matchClass(name: []const u8, text_byte: u8, options: Options) Error!bool {
    const c = text_byte;
    if (std.mem.eql(u8, name, "alnum")) return isAlpha(c) or isDigit(c);
    if (std.mem.eql(u8, name, "alpha")) return isAlpha(c);
    if (std.mem.eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (std.mem.eql(u8, name, "cntrl")) return c < 0x20 or c == 0x7f;
    if (std.mem.eql(u8, name, "digit")) return isDigit(c);
    if (std.mem.eql(u8, name, "graph")) return c > 0x20 and c < 0x7f;
    if (std.mem.eql(u8, name, "lower")) return isLower(c);
    if (std.mem.eql(u8, name, "print")) return c >= 0x20 and c < 0x7f;
    if (std.mem.eql(u8, name, "punct")) return c > 0x20 and c < 0x7f and !isAlpha(c) and !isDigit(c);
    if (std.mem.eql(u8, name, "space")) return c == ' ' or (c >= '\t' and c <= '\r');
    if (std.mem.eql(u8, name, "upper")) return isUpper(c) or (options.case_fold and isLower(c));
    if (std.mem.eql(u8, name, "xdigit")) return isDigit(c) or (c | 0x20) >= 'a' and (c | 0x20) <= 'f';
    return error.InvalidPattern;
}

fn fold(c: u8) u8 {
    return if (isUpper(c)) c + ('a' - 'A') else c;
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isAlpha(c: u8) bool {
    return isUpper(c) or isLower(c);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const expect = std.testing.expect;
const expectError = std.testing.expectError;

fn yes(pattern: []const u8, text: []const u8) !void {
    try expect(try match(pattern, text, .{}));
}

fn no(pattern: []const u8, text: []const u8) !void {
    try expect(!try match(pattern, text, .{}));
}

test "literals must match in full" {
    try yes("foo.c", "foo.c");
    try no("foo.c", "foo.cc");
    try no("foo.c", "afoo.c");
    try yes("", "");
    try no("", "x");
    try no("x", "");
}

test "star matches a run but never a slash under pathname" {
    try yes("*.c", "foo.c");
    try yes("*.c", ".c");
    try no("*.c", "foo.h");
    try no("*.c", "sub/foo.c");
    try yes("sub/*.c", "sub/foo.c");
    try no("sub/*", "sub/dir/foo.c");
    try yes("*", "foo");
    try no("*", "a/b");
    try yes("a*b*c", "axxbyyc");
    try no("a*b*c", "axxbyyd");
}

test "star crosses slashes when pathname is off" {
    try expect(try match("*.c", "sub/foo.c", .{ .pathname = false }));
    try expect(try match("*", "a/b/c", .{ .pathname = false }));
    try expect(!try match("a/**/b", "a/b", .{ .pathname = false }));
    try expect(try match("a/**/b", "a//b", .{ .pathname = false }));
}

test "question mark is one byte and not a slash" {
    try yes("?oo", "foo");
    try no("?oo", "oo");
    try no("a?b", "a/b");
    try expect(try match("a?b", "a/b", .{ .pathname = false }));
    try yes("a/?/b", "a/x/b");
}

test "double star as a whole component" {
    try yes("a/**/b", "a/b");
    try yes("a/**/b", "a/x/b");
    try yes("a/**/b", "a/x/y/b");
    try no("a/**/b", "a/x/y/c");
    try no("a/**/b", "b");
    try yes("**/foo", "foo");
    try yes("**/foo", "a/foo");
    try yes("**/foo", "a/b/c/foo");
    try no("**/foo", "a/foobar");
    try yes("a/**", "a/b");
    try yes("a/**", "a/b/c");
    try yes("a/**", "a/");
    try no("a/**", "a");
    try no("a/**", "b/c");
    try yes("**", "a/b/c");
    try yes("a/**/**/b", "a/x/y/b");
    try yes("**/*.c", "a/b/foo.c");
    try yes("**/*.c", "foo.c");
}

test "double star that is not a whole component is just a star" {
    try yes("a**b", "axxb");
    try no("a**b", "ax/xb");
    try yes("a**/b", "axx/b");
    try no("a**/b", "a/x/b");
    try yes("**b", "axb");
    try no("**b", "a/xb");
}

test "a permissive star before a restrictive one still backtracks" {
    try yes("a/**/x*y", "a/x/xzy");
    try no("a/**/x*y", "a/x/x/zy");
    try yes("**/x*y", "p/q/xzy");
}

test "bracket sets, ranges and negation" {
    try yes("[abc]", "b");
    try no("[abc]", "d");
    try yes("[a-z]", "q");
    try no("[a-z]", "Q");
    try yes("[!abc]", "d");
    try no("[!abc]", "a");
    try yes("[^abc]", "d");
    try no("[^abc]", "a");
    try yes("[]abc]", "]");
    try yes("[]abc]", "a");
    try no("[]abc]", "x");
    try yes("[!]a]", "b");
    try no("[!]a]", "]");
    try yes("f[aeiou]o", "foo");
    try yes("[a-c-e]", "-");
    try yes("[a-]", "-");
    try no("[a-z]", "/");
    try no("[/]", "/");
    try expect(try match("[/]", "/", .{ .pathname = false }));
}

test "bracket escapes with backslash" {
    try yes("[\\]]", "]");
    try yes("[\\\\]", "\\");
    try no("[\\]]", "\\");
    try yes("[a\\-c]", "-");
    try no("[a\\-c]", "b");
}

test "posix character classes" {
    try yes("[[:alnum:]]", "7");
    try yes("[[:alnum:]]", "x");
    try no("[[:alnum:]]", "-");
    try yes("[[:alpha:]]", "x");
    try no("[[:alpha:]]", "7");
    try yes("[[:blank:]]", " ");
    try yes("[[:blank:]]", "\t");
    try no("[[:blank:]]", "\n");
    try yes("[[:cntrl:]]", "\x01");
    try no("[[:cntrl:]]", "a");
    try yes("[[:digit:]]", "3");
    try no("[[:digit:]]", "a");
    try yes("[[:graph:]]", "!");
    try no("[[:graph:]]", " ");
    try yes("[[:lower:]]", "a");
    try no("[[:lower:]]", "A");
    try yes("[[:print:]]", " ");
    try no("[[:print:]]", "\x7f");
    try yes("[[:punct:]]", ",");
    try no("[[:punct:]]", "a");
    try yes("[[:space:]]", " ");
    try yes("[[:space:]]", "\n");
    try no("[[:space:]]", "a");
    try yes("[[:upper:]]", "A");
    try no("[[:upper:]]", "a");
    try yes("[[:xdigit:]]", "f");
    try yes("[[:xdigit:]]", "F");
    try no("[[:xdigit:]]", "g");
    try yes("[[:digit:][:alpha:]]", "z");
    try yes("x[[:digit:]]y", "x4y");
    try no("[![:digit:]]", "4");
    try yes("[![:digit:]]", "a");
    try no("[[:alpha:]]", "\xe9");
}

test "a bracket that only looks like a class keeps the bracket literal" {
    try yes("[[:foo]", "[");
    try yes("[[:foo]", ":");
    try yes("[[:foo]", "o");
    try no("[[:foo]", "x");
}

test "malformed brackets are reported" {
    try expectError(error.InvalidPattern, match("[abc", "a", .{}));
    try expectError(error.InvalidPattern, match("[", "a", .{}));
    try expectError(error.InvalidPattern, match("[!", "a", .{}));
    try expectError(error.InvalidPattern, match("[a\\", "a", .{}));
    try expectError(error.InvalidPattern, match("[[:bogus:]]", "a", .{}));
    try expectError(error.InvalidPattern, match("[[:alpha:", "a", .{}));
    // Never reached, so never reported.
    try no("x[abc", "y");
    try no("[abc", "");
}

test "backslash escapes the next byte" {
    try yes("\\*", "*");
    try no("\\*", "x");
    try yes("\\?", "?");
    try yes("\\[abc", "[abc");
    try yes("a\\\\b", "a\\b");
    try yes("\\a", "a");
    // A trailing lone backslash matches nothing, which is what git does:
    // it reads the byte past the end of the pattern as NUL.
    try no("a\\", "a\\");
    try no("a\\", "ab");
    try no("\\", "\\");
}

test "case folding is ascii only" {
    const fold_opts: Options = .{ .case_fold = true };
    try expect(try match("FOO.c", "foo.C", fold_opts));
    try expect(!try match("FOO.c", "foo.C", .{}));
    try expect(try match("*.TXT", "readme.txt", fold_opts));
    try expect(try match("[a-z]", "Q", fold_opts));
    try expect(try match("[[:upper:]]", "a", fold_opts));
    try expect(try match("[[:lower:]]", "A", fold_opts));
    // git folds the text byte but not a pattern byte behind a backslash.
    try expect(try match("\\b", "B", fold_opts));
    try expect(!try match("\\A", "a", fold_opts));
    try expect(!try match("[A]", "a", fold_opts));
    try expect(try match("[a]", "A", fold_opts));
    // Bytes above ASCII are left alone.
    try expect(!try match("\xc3\xa9", "\xc3\x89", fold_opts));
}

test "matching is over bytes, not code points" {
    try yes("?", "\xff");
    try no("?", "\xc3\xa9");
    try yes("??", "\xc3\xa9");
    try yes("*", "\x00\x01\x02");
    try yes("a\x00b", "a\x00b");
}

test "gitignore-shaped patterns" {
    try yes("*.o", "foo.o");
    try no("*.o", "src/foo.o");
    try yes("**/*.o", "src/foo.o");
    try yes("build/**", "build/x/y");
    try yes("doc/frotz/**", "doc/frotz/a/b");
    try no("doc/frotz/**", "doc/frotzz");
    try yes("a/**/b/**/c", "a/x/b/y/c");
    try yes("a/**/b/**/c", "a/b/c");
}

test "pathological star pattern finishes without hanging" {
    const text = "a" ** 400;
    try no("*a*a*a*a*a*a*a*a*b", text);
    try expect(!try match("*a*a*a*a*a*a*a*a*b", text, .{ .pathname = false }));
    try yes("*a*a*a*a*a*a*a*a*a", text);
}

test "nesting past the recursion bound is refused" {
    // Every star tried is a frame, two to each `**/*a/`, so six hundred of
    // them run past the cap of 1024.
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(std.testing.allocator);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..600) |_| {
        try pattern.appendSlice(std.testing.allocator, "**/*a/");
        try text.appendSlice(std.testing.allocator, "a/");
    }
    try pattern.append(std.testing.allocator, 'z');
    try text.append(std.testing.allocator, 'z');
    try expectError(error.PatternTooComplex, match(pattern.items, text.items, .{}));

    // The same shape just under the cap still answers.
    var short: std.ArrayList(u8) = .empty;
    defer short.deinit(std.testing.allocator);
    var short_text: std.ArrayList(u8) = .empty;
    defer short_text.deinit(std.testing.allocator);
    for (0..8) |_| {
        try short.appendSlice(std.testing.allocator, "**/*a/");
        try short_text.appendSlice(std.testing.allocator, "a/");
    }
    try short.append(std.testing.allocator, 'z');
    try short_text.append(std.testing.allocator, 'z');
    try expect(try match(short.items, short_text.items, .{}));
}

test "alternating ** and * patterns give up as git's do rather than backtracking exponentially" {
    // The reviewer's shape: twelve `**/x*/` against forty `x/` and a `z`,
    // which backtracked for minutes and git answers in milliseconds.
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(std.testing.allocator);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..12) |_| try pattern.appendSlice(std.testing.allocator, "**/x*/");
    try pattern.append(std.testing.allocator, 'y');
    for (0..40) |_| try text.appendSlice(std.testing.allocator, "x/");
    try text.append(std.testing.allocator, 'z');
    try no(pattern.items, text.items);
    text.items[text.items.len - 1] = 'y';
    try yes(pattern.items, text.items);
}

test "fuzz: any pattern and text answer or name an error" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var pattern_buf: [64]u8 = undefined;
    var text_buf: [64]u8 = undefined;
    const pattern = pattern_buf[0..smith.slice(&pattern_buf)];
    const text = text_buf[0..smith.slice(&text_buf)];
    _ = match(pattern, text, .{}) catch return;
    _ = match(pattern, text, .{ .pathname = false, .case_fold = true }) catch return;
}
