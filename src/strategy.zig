//! git's merge strategy options: the words `-X` hands the ort strategy, as
//! `merge`, `cherry-pick`, `revert` and `rebase` take them and as they are
//! kept between the steps of a sequence.
//!
//! The words are kept as given, because that is how git keeps them: in
//! `.git/sequencer/opts` one `strategy-option` per word, and in
//! `.git/rebase-merge/strategy_opts` all of them quoted onto one line. What
//! they mean is worked out when a merge is made, on top of the settings
//! from configuration, the later word winning where two disagree -- git's
//! `parse_merge_opt`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const blobmerge = @import("blobmerge.zig");
const textdiff = @import("textdiff.zig");
const similarity = @import("similarity.zig");

/// Errors from reading strategy options.
pub const Error = error{
    /// A word git's `-X` does not take.
    UnknownStrategyOption,
    /// A word git takes that this merge does not do: `subtree` and the
    /// whitespace options.
    UnsupportedStrategyOption,
};

/// A line diff as `diff.algorithm` and `-X diff-algorithm` name it: an
/// algorithm, and for Myers whether to prove the script minimal.
pub const LineDiff = struct {
    algorithm: textdiff.Algorithm,
    minimal: bool = false,

    /// git's `parse_algorithm_value`: `myers` or `default`, `minimal`,
    /// `patience` or `histogram`, in any case. `null` for anything else.
    pub fn parse(text: []const u8) ?LineDiff {
        if (std.ascii.eqlIgnoreCase(text, "myers") or std.ascii.eqlIgnoreCase(text, "default")) return .{ .algorithm = .myers };
        if (std.ascii.eqlIgnoreCase(text, "minimal")) return .{ .algorithm = .myers, .minimal = true };
        if (std.ascii.eqlIgnoreCase(text, "patience")) return .{ .algorithm = .patience };
        if (std.ascii.eqlIgnoreCase(text, "histogram")) return .{ .algorithm = .histogram };
        return null;
    }
};

/// What a merge does with its content and its renames, once configuration
/// and the strategy options have had their say.
pub const Settings = struct {
    /// `-X ours`, `-X theirs`.
    favor: blobmerge.Favor = .none,
    /// The line diff the content merges take: histogram unless
    /// `diff.algorithm` or a strategy option says otherwise.
    algorithm: textdiff.Algorithm = .histogram,
    /// Prove Myers' scripts minimal, including those patience and
    /// histogram fall back to.
    minimal: bool = false,
    /// Whether renames are followed.
    renames: bool = true,
    /// How much of a file must survive for a rename, out of
    /// `similarity.max_score`; zero is git's default of half.
    rename_score: u32 = 0,
    /// Whether each side goes through the line-ending conversion before it
    /// is merged: `merge.renormalize`, `-X renormalize`.
    renormalize: bool = false,

    /// Take `diff.algorithm`'s value, as git's merge configuration does:
    /// the algorithm replaced, `minimal` set only by `minimal` itself.
    /// `null` for a value git refuses.
    pub fn configureAlgorithm(s: *Settings, text: []const u8) ?void {
        const diff = LineDiff.parse(text) orelse return null;
        s.algorithm = diff.algorithm;
        if (diff.minimal) s.minimal = true;
    }

    /// Apply one `-X` word: git's `parse_merge_opt`.
    pub fn apply(s: *Settings, word: []const u8) Error!void {
        if (word.len == 0) return error.UnknownStrategyOption;
        if (std.mem.eql(u8, word, "ours")) {
            s.favor = .ours;
        } else if (std.mem.eql(u8, word, "theirs")) {
            s.favor = .theirs;
        } else if (std.mem.eql(u8, word, "patience")) {
            s.algorithm = .patience;
        } else if (std.mem.eql(u8, word, "histogram")) {
            s.algorithm = .histogram;
        } else if (std.mem.startsWith(u8, word, "diff-algorithm=")) {
            const diff = LineDiff.parse(word["diff-algorithm=".len..]) orelse return error.UnknownStrategyOption;
            s.algorithm = diff.algorithm;
            s.minimal = diff.minimal;
        } else if (std.mem.eql(u8, word, "renormalize")) {
            s.renormalize = true;
        } else if (std.mem.eql(u8, word, "no-renormalize")) {
            s.renormalize = false;
        } else if (std.mem.eql(u8, word, "no-renames")) {
            s.renames = false;
        } else if (std.mem.eql(u8, word, "find-renames")) {
            s.renames = true;
            s.rename_score = 0;
        } else if (std.mem.startsWith(u8, word, "find-renames=") or std.mem.startsWith(u8, word, "rename-threshold=")) {
            const value = word[std.mem.indexOfScalar(u8, word, '=').? + 1 ..];
            const parsed = parseRenameScore(value);
            if (parsed.rest.len != 0) return error.UnknownStrategyOption;
            s.rename_score = parsed.score;
            s.renames = true;
        } else if (std.mem.eql(u8, word, "subtree") or std.mem.startsWith(u8, word, "subtree=") or
            std.mem.eql(u8, word, "ignore-space-change") or std.mem.eql(u8, word, "ignore-all-space") or
            std.mem.eql(u8, word, "ignore-space-at-eol") or std.mem.eql(u8, word, "ignore-cr-at-eol"))
        {
            return error.UnsupportedStrategyOption;
        } else return error.UnknownStrategyOption;
    }
};

/// git's `parse_rename_score`: `50`, `.5` and `50%` are all half. Digits
/// are a fraction whose denominator grows by ten with each one, a dot only
/// resets it, and `%` makes it a percentage and ends the number. Returns
/// the score out of `similarity.max_score` and what follows the number.
pub fn parseRenameScore(text: []const u8) struct { score: u32, rest: []const u8 } {
    var num: u64 = 0;
    var scale: u64 = 1;
    var dot = false;
    var at: usize = 0;
    while (at < text.len) : (at += 1) {
        const c = text[at];
        if (!dot and c == '.') {
            scale = 1;
            dot = true;
        } else if (c == '%') {
            scale = if (dot) scale * 100 else 100;
            at += 1;
            break;
        } else if (c >= '0' and c <= '9') {
            if (scale < 100000) {
                scale *= 10;
                num = num * 10 + (c - '0');
            }
        } else break;
    }
    const score: u32 = if (num >= scale) similarity.max_score else @intCast(similarity.max_score * num / scale);
    return .{ .score = score, .rest = text[at..] };
}

/// The words as git writes them into `rebase-merge/strategy_opts`: each in
/// double quotes, `"` and `\` escaped, separated by spaces -- git's
/// `quote_cmdline`. The result is the caller's.
pub fn quote(gpa: Allocator, words: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (words, 0..) |word, i| {
        if (i != 0) try out.append(gpa, ' ');
        try out.append(gpa, '"');
        for (word) |c| {
            if (c == '"' or c == '\\') try out.append(gpa, '\\');
            try out.append(gpa, c);
        }
        try out.append(gpa, '"');
    }
    return out.toOwnedSlice(gpa);
}

/// Errors from splitting a `strategy_opts` line.
pub const SplitError = error{
    /// A quote is left open, or the line ends in a backslash.
    MalformedStrategyOptions,
} || Allocator.Error;

/// The words of a `strategy_opts` line, as git's `parse_strategy_opts`
/// reads them: one leading space skipped, split as `split_cmdline` splits
/// a command line, and a leading `--` dropped from each, which is how an
/// older git wrote them. The words and the slice are the caller's, in
/// `arena`.
pub fn split(arena: Allocator, line_in: []const u8) SplitError![]const []const u8 {
    var line = line_in;
    if (line.len != 0 and line[0] == ' ') line = line[1..];
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var quoted: u8 = 0;
    var at: usize = 0;
    while (at < line.len) {
        const c = line[at];
        if (quoted == 0 and std.ascii.isWhitespace(c)) {
            try words.append(arena, try word.toOwnedSlice(arena));
            at += 1;
            while (at < line.len and std.ascii.isWhitespace(line[at])) at += 1;
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
                if (at == line.len) return error.MalformedStrategyOptions;
                ch = line[at];
            }
            try word.append(arena, ch);
            at += 1;
        }
    }
    if (quoted != 0) return error.MalformedStrategyOptions;
    try words.append(arena, try word.toOwnedSlice(arena));
    for (words.items) |*w| {
        if (std.mem.startsWith(u8, w.*, "--")) w.* = w.*[2..];
    }
    return words.items;
}

test "strategy options set what git's parse_merge_opt sets, the later word winning" {
    var s: Settings = .{};
    try s.apply("theirs");
    try s.apply("diff-algorithm=minimal");
    try std.testing.expectEqual(blobmerge.Favor.theirs, s.favor);
    try std.testing.expectEqual(textdiff.Algorithm.myers, s.algorithm);
    try std.testing.expect(s.minimal);
    // `patience` keeps `minimal`; `diff-algorithm=` clears it.
    try s.apply("patience");
    try std.testing.expectEqual(textdiff.Algorithm.patience, s.algorithm);
    try std.testing.expect(s.minimal);
    try s.apply("diff-algorithm=Histogram");
    try std.testing.expect(!s.minimal);
    try std.testing.expectEqual(textdiff.Algorithm.histogram, s.algorithm);
    try s.apply("no-renames");
    try std.testing.expect(!s.renames);
    try s.apply("find-renames=40%");
    try std.testing.expect(s.renames);
    try std.testing.expectEqual(@as(u32, 24000), s.rename_score);
    try s.apply("rename-threshold=.5");
    try std.testing.expectEqual(@as(u32, 30000), s.rename_score);
    try std.testing.expectError(error.UnknownStrategyOption, s.apply("find-renames=40%x"));
    try std.testing.expectError(error.UnknownStrategyOption, s.apply("diff-algorithm=fast"));
    try std.testing.expectError(error.UnknownStrategyOption, s.apply("frobnicate"));
    try std.testing.expectError(error.UnsupportedStrategyOption, s.apply("ignore-space-change"));
}

test "a rename score is read as git reads one" {
    try std.testing.expectEqual(@as(u32, 30000), parseRenameScore("50").score);
    try std.testing.expectEqual(@as(u32, 30000), parseRenameScore("5").score);
    try std.testing.expectEqual(@as(u32, 30000), parseRenameScore("50%").score);
    try std.testing.expectEqual(@as(u32, 6000), parseRenameScore("10%").score);
    try std.testing.expectEqual(@as(u32, 60000), parseRenameScore("100%").score);
    try std.testing.expectEqualStrings("x", parseRenameScore("40x").rest);
}

test "strategy options quote and split back as git's rebase keeps them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const words = [_][]const u8{ "diff-algorithm=patience", "find-renames=40%", "odd \"word\\" };
    const line = try quote(arena, &words);
    try std.testing.expectEqualStrings("\"diff-algorithm=patience\" \"find-renames=40%\" \"odd \\\"word\\\\\"", line);
    const back = try split(arena, line);
    try std.testing.expectEqual(words.len, back.len);
    for (words, back) |want, got| try std.testing.expectEqualStrings(want, got);
    // What an older git wrote.
    const old = try split(arena, " --ours --diff-algorithm=minimal");
    try std.testing.expectEqualStrings("ours", old[0]);
    try std.testing.expectEqualStrings("diff-algorithm=minimal", old[1]);
    try std.testing.expectError(error.MalformedStrategyOptions, split(arena, "\"open"));
}

fn fuzzSplit(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const words = split(arena_state.allocator(), buf[0..len]) catch |err| switch (err) {
        error.MalformedStrategyOptions => return,
        else => return err,
    };
    // Whatever split read, quoting it and splitting again gives it back,
    // unless a word began with the `--` the reader drops.
    for (words) |w| if (std.mem.startsWith(u8, w, "--")) return;
    const again = try split(arena_state.allocator(), try quote(arena_state.allocator(), words));
    try std.testing.expectEqual(words.len, again.len);
    for (words, again) |a, b| try std.testing.expectEqualStrings(a, b);
}

test "fuzz: any strategy_opts line splits or is a named failure, and round-trips" {
    try std.testing.fuzz({}, fuzzSplit, .{});
}
