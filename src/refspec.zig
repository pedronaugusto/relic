//! Refspecs: the rule that says which refs a fetch takes and where it keeps
//! them, and which refs a push sends and where they land.
//!
//! `[+]<src>:<dst>`. A `+` lets the update skip the fast-forward check; a
//! `*` on both sides makes a pattern, and whatever it stands for on one side
//! it stands for on the other; a leading `^` makes a negative refspec, which
//! takes nothing itself and removes what it matches from everything the
//! others take. On a push, `:<dst>` deletes `<dst>` and a lone `:` pushes
//! every branch the two sides share a name for.
//!
//! The rules are git's `parse_refspec`, down to the colon being the *last*
//! one, `@` standing for `HEAD`, and a fetch source of forty hexadecimal
//! digits being an object name rather than a ref. A refspec is read from a
//! configuration file or a caller and neither is trusted, so a string git
//! would refuse is `error.InvalidRefspec` here too.

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("hash.zig");

/// Which operation a refspec is read for. The two read the same syntax with
/// different rules: a fetch may leave the destination out, a push may leave
/// the source out.
pub const Direction = enum { fetch, push };

pub const ParseError = error{
    /// A refspec git's own parser refuses: a pattern on one side only, an
    /// invalid ref name, a negative refspec with a destination or an object
    /// name, or an empty push destination.
    InvalidRefspec,
};

/// One refspec. The names are borrowed from the text it was parsed from.
pub const Refspec = struct {
    /// `+`: update even when the new value does not descend from the old.
    force: bool = false,
    /// `^`: take nothing, and remove what this matches from what the others
    /// take.
    negative: bool = false,
    /// A push's lone `:` (or `+:`): every branch both sides have.
    matching: bool = false,
    /// Both sides hold a `*`.
    pattern: bool = false,
    /// A fetch source that is a full object name rather than a ref.
    exact_oid: bool = false,
    /// The source side. Empty in a push's `:<dst>`, which deletes `<dst>`,
    /// and in a fetch's `:<dst>`, which means `HEAD`.
    src: []const u8,
    /// The destination, or `null` when the refspec has no colon. An empty
    /// destination on a fetch means the ref is fetched and not kept.
    dst: ?[]const u8,

    /// Read one refspec, as `direction` reads it.
    pub fn parse(text: []const u8, direction: Direction) ParseError!Refspec {
        var spec: Refspec = .{ .src = "", .dst = null };
        var lhs = text;
        if (lhs.len != 0 and lhs[0] == '+') {
            spec.force = true;
            lhs = lhs[1..];
        } else if (lhs.len != 0 and lhs[0] == '^') {
            spec.negative = true;
            lhs = lhs[1..];
        }

        const colon = std.mem.lastIndexOfScalar(u8, lhs, ':');
        if (spec.negative and colon != null) return error.InvalidRefspec;

        // A push's lone `:` pushes the branches both sides share.
        if (direction == .push and colon != null and colon.? == 0 and lhs.len == 1) {
            spec.matching = true;
            return spec;
        }

        var dst_glob = false;
        if (colon) |at| {
            const rhs = lhs[at + 1 ..];
            dst_glob = std.mem.indexOfScalar(u8, rhs, '*') != null;
            spec.dst = rhs;
        }
        const src = if (colon) |at| lhs[0..at] else lhs;
        var glob = dst_glob;
        if (std.mem.indexOfScalar(u8, src, '*') != null) {
            // A pattern on the source must have one on the destination, and
            // a fetch pattern must have a destination at all.
            if ((colon != null and !dst_glob) or (colon == null and !spec.negative and direction == .fetch)) {
                return error.InvalidRefspec;
            }
            glob = true;
        } else if (colon != null and dst_glob) {
            return error.InvalidRefspec;
        }
        spec.pattern = glob;
        spec.src = if (std.mem.eql(u8, src, "@")) "HEAD" else src;

        const format: Format = .{ .allow_onelevel = true, .pattern = glob };
        if (spec.negative) {
            if (spec.src.len == 0) return error.InvalidRefspec;
            if (isFullHex(spec.src)) return error.InvalidRefspec;
            if (!checkRefFormat(spec.src, format)) return error.InvalidRefspec;
            return spec;
        }

        switch (direction) {
            .fetch => {
                if (spec.src.len == 0) {
                    // Empty means `HEAD`.
                } else if (isFullHex(spec.src)) {
                    spec.exact_oid = true;
                } else if (!checkRefFormat(spec.src, format)) {
                    return error.InvalidRefspec;
                }
                if (spec.dst) |dst| {
                    if (dst.len != 0 and !checkRefFormat(dst, format)) return error.InvalidRefspec;
                }
            },
            .push => {
                // Any source goes that is not a pattern: it may be an object
                // name or an expression, which only the pushing repository
                // can resolve.
                if (spec.src.len != 0 and glob and !checkRefFormat(spec.src, format)) {
                    return error.InvalidRefspec;
                }
                if (spec.dst) |dst| {
                    if (dst.len == 0) return error.InvalidRefspec;
                    if (!checkRefFormat(dst, format)) return error.InvalidRefspec;
                } else if (!checkRefFormat(spec.src, format)) {
                    return error.InvalidRefspec;
                }
            },
        }
        return spec;
    }

    /// Whether `name` is a source this refspec names: equal to it, or
    /// matching its pattern.
    pub fn matchesSource(spec: Refspec, name: []const u8) bool {
        if (spec.matching) return false;
        if (spec.pattern) return matchPattern(spec.src, name) != null;
        return std.mem.eql(u8, spec.src, name);
    }

    /// Where a source ref lands: the destination with the pattern's match
    /// put in place of its `*`, or the destination itself. `null` when
    /// `name` does not match or when there is no destination to land on.
    /// The result is the caller's.
    pub fn mapSource(spec: Refspec, gpa: Allocator, name: []const u8) Allocator.Error!?[]u8 {
        if (spec.negative or spec.matching) return null;
        const dst = spec.dst orelse return null;
        if (dst.len == 0) return null;
        if (!spec.pattern) {
            if (!std.mem.eql(u8, spec.src, name)) return null;
            return try gpa.dupe(u8, dst);
        }
        const middle = matchPattern(spec.src, name) orelse return null;
        return try substitute(gpa, dst, middle);
    }

    /// The source a destination ref came from: `mapSource` the other way
    /// round, which is how a remote-tracking ref finds the remote ref it
    /// tracks. The result is the caller's.
    pub fn mapDestination(spec: Refspec, gpa: Allocator, name: []const u8) Allocator.Error!?[]u8 {
        if (spec.negative or spec.matching) return null;
        const dst = spec.dst orelse return null;
        if (dst.len == 0) return null;
        if (!spec.pattern) {
            if (!std.mem.eql(u8, dst, name)) return null;
            return try gpa.dupe(u8, spec.src);
        }
        const middle = matchPattern(dst, name) orelse return null;
        return try substitute(gpa, spec.src, middle);
    }
};

/// Whether any negative refspec in `specs` removes `name`.
pub fn excluded(specs: []const Refspec, name: []const u8) bool {
    for (specs) |spec| {
        if (!spec.negative) continue;
        if (spec.pattern) {
            if (matchPattern(spec.src, name) != null) return true;
        } else if (std.mem.eql(u8, spec.src, name)) return true;
    }
    return false;
}

/// What `*` stood for when `name` matches `pattern`, or `null`. The result
/// borrows `name`.
///
/// git's `match_name_with_pattern`: the text before the star is a prefix,
/// the text after it a suffix, and the two may not overlap.
pub fn matchPattern(pattern: []const u8, name: []const u8) ?[]const u8 {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return null;
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    if (name.len < prefix.len + suffix.len) return null;
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    return name[prefix.len .. name.len - suffix.len];
}

fn substitute(gpa: Allocator, pattern: []const u8, middle: []const u8) Allocator.Error![]u8 {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return gpa.dupe(u8, pattern);
    return std.mem.concat(gpa, u8, &.{ pattern[0..star], middle, pattern[star + 1 ..] });
}

fn isFullHex(text: []const u8) bool {
    if (text.len != hash.Kind.sha1.hexLen() and text.len != hash.Kind.sha256.hexLen()) return false;
    for (text) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// What `checkRefFormat` allows beyond a full ref name.
pub const Format = struct {
    /// A name with no `/`, such as `HEAD` or `main`.
    allow_onelevel: bool = false,
    /// One `*`, anywhere, for a refspec pattern.
    pattern: bool = false,
};

/// git's `check_refname_format`: whether `name` is a name a ref may carry.
///
/// No component may begin with `.` or end with `.lock`, be empty, or hold
/// `..`, `@{`, a control character, a space, `~`, `^`, `:`, `?`, `[`, `\`
/// or — outside one pattern star — `*`. The whole may not be `@`, end with
/// `.` or `/`, or (unless `allow_onelevel`) be a single component.
pub fn checkRefFormat(name: []const u8, format: Format) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "@")) return false;
    var stars_left: u8 = if (format.pattern) 1 else 0;
    var components: usize = 0;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |component| {
        if (component.len == 0) return false;
        if (component[0] == '.') return false;
        if (std.mem.endsWith(u8, component, ".lock")) return false;
        var previous: u8 = 0;
        for (component) |c| {
            switch (c) {
                0...0x20, 0x7f, '~', '^', ':', '?', '[', '\\' => return false,
                '*' => {
                    if (stars_left == 0) return false;
                    stars_left -= 1;
                },
                '.' => if (previous == '.') return false,
                '{' => if (previous == '@') return false,
                else => {},
            }
            previous = c;
        }
        components += 1;
    }
    if (name[name.len - 1] == '.') return false;
    if (!format.allow_onelevel and components < 2) return false;
    return true;
}

const testing = std.testing;
const testgit = @import("testgit.zig");

test "a fetch refspec reads as git reads it, force and pattern and all" {
    const spec = try Refspec.parse("+refs/heads/*:refs/remotes/origin/*", .fetch);
    try testing.expect(spec.force);
    try testing.expect(spec.pattern);
    try testing.expectEqualStrings("refs/heads/*", spec.src);
    try testing.expectEqualStrings("refs/remotes/origin/*", spec.dst.?);

    const gpa = testing.allocator;
    const mapped = (try spec.mapSource(gpa, "refs/heads/topic/one")).?;
    defer gpa.free(mapped);
    try testing.expectEqualStrings("refs/remotes/origin/topic/one", mapped);
    const back = (try spec.mapDestination(gpa, "refs/remotes/origin/main")).?;
    defer gpa.free(back);
    try testing.expectEqualStrings("refs/heads/main", back);
    try testing.expect(try spec.mapSource(gpa, "refs/tags/v1") == null);

    const at = try Refspec.parse("@:refs/heads/x", .fetch);
    try testing.expectEqualStrings("HEAD", at.src);
    const hex = try Refspec.parse("0123456789012345678901234567890123456789:refs/heads/x", .fetch);
    try testing.expect(hex.exact_oid);
    const no_dst = try Refspec.parse("main", .fetch);
    try testing.expect(no_dst.dst == null);
    const empty_dst = try Refspec.parse("main:", .fetch);
    try testing.expectEqualStrings("", empty_dst.dst.?);
}

test "a partial glob matches around its star, and the two sides move together" {
    const gpa = testing.allocator;
    const spec = try Refspec.parse("refs/heads/feature-*-wip:refs/remotes/o/f-*", .fetch);
    const mapped = (try spec.mapSource(gpa, "refs/heads/feature-login-wip")).?;
    defer gpa.free(mapped);
    try testing.expectEqualStrings("refs/remotes/o/f-login", mapped);
    try testing.expect(!spec.matchesSource("refs/heads/feature-wip"));
    try testing.expect(spec.matchesSource("refs/heads/feature--wip"));
}

test "negative refspecs remove what they match and take nothing" {
    const specs = [_]Refspec{
        try Refspec.parse("refs/heads/*:refs/remotes/origin/*", .fetch),
        try Refspec.parse("^refs/heads/secret-*", .fetch),
        try Refspec.parse("^refs/heads/wip", .fetch),
    };
    try testing.expect(excluded(&specs, "refs/heads/secret-plan"));
    try testing.expect(excluded(&specs, "refs/heads/wip"));
    try testing.expect(!excluded(&specs, "refs/heads/wipe"));
    try testing.expect(!excluded(&specs, "refs/heads/main"));
    try testing.expect(try specs[1].mapSource(testing.allocator, "refs/heads/secret-x") == null);
}

test "a push refspec deletes with an empty source and matches with a lone colon" {
    const delete = try Refspec.parse(":refs/heads/gone", .push);
    try testing.expectEqualStrings("", delete.src);
    try testing.expectEqualStrings("refs/heads/gone", delete.dst.?);
    const matching = try Refspec.parse(":", .push);
    try testing.expect(matching.matching);
    const forced = try Refspec.parse("+:", .push);
    try testing.expect(forced.matching and forced.force);
    const expression = try Refspec.parse("HEAD~2:refs/heads/older", .push);
    try testing.expectEqualStrings("HEAD~2", expression.src);
}

test "what git refuses is refused by name" {
    for ([_][]const u8{
        "refs/heads/*:refs/remotes/origin/main", // a pattern on one side
        "refs/heads/main:refs/remotes/origin/*",
        "refs/heads/*", // a fetch pattern with nowhere to go
        "^refs/heads/a:refs/heads/b", // a negative with a destination
        "^0123456789012345678901234567890123456789",
        "^",
        "refs/heads/a..b:refs/x",
        "refs/heads/a:refs/heads/b.lock",
        "refs/heads/**:refs/remotes/**",
    }) |text| {
        try testing.expectError(error.InvalidRefspec, Refspec.parse(text, .fetch));
    }
    for ([_][]const u8{
        "refs/heads/main:", // an empty push destination
        "refs/heads/*:refs/heads/x",
        "HEAD~1", // an expression with nowhere named to go
    }) |text| {
        try testing.expectError(error.InvalidRefspec, Refspec.parse(text, .push));
    }
}

test "ref name format follows check_refname_format" {
    try testing.expect(checkRefFormat("refs/heads/main", .{}));
    try testing.expect(!checkRefFormat("main", .{}));
    try testing.expect(checkRefFormat("main", .{ .allow_onelevel = true }));
    try testing.expect(checkRefFormat("refs/heads/*", .{ .pattern = true }));
    try testing.expect(checkRefFormat("refs/heads/a*b", .{ .pattern = true }));
    try testing.expect(!checkRefFormat("refs/*/a*b", .{ .pattern = true }));
    try testing.expect(!checkRefFormat("refs/heads/*", .{}));
    for ([_][]const u8{
        "refs/heads/.x", "refs/heads/x.",  "refs/heads/x.lock", "refs//heads",
        "refs/heads/",   "/refs/heads",    "refs/heads/a@{b",   "refs/heads/a b",
        "refs/heads/a~", "refs/heads/a^b", "refs/heads/a:b",    "refs/heads/a?",
        "refs/heads/a[", "refs/heads/a\\", "@",                 "refs/heads/a..b",
    }) |name| {
        try testing.expect(!checkRefFormat(name, .{ .allow_onelevel = true }));
    }
}

test "ref name format agrees with git check-ref-format" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    repo.report_failures = false;
    for ([_][]const u8{
        "refs/heads/main",   "refs/heads/a.b",   "refs/heads/a..b", "refs/heads/.a",
        "refs/heads/a.lock", "refs/heads/a@b",   "refs/heads/a@{b", "refs/tags/v1.0",
        "refs/heads/-dash",  "refs/heads/a/b/c", "refs/heads/a//b", "refs/heads/trailing.",
        "refs/x",
        "refs/heads/emoji-é",
        "refs/heads/q?",     "refs/heads/@",
    }) |name| {
        const ours = checkRefFormat(name, .{});
        const theirs = if (repo.exec(io, &.{ "check-ref-format", name })) true else |_| false;
        try testing.expectEqual(theirs, ours);
    }
    for ([_][]const u8{ "refs/heads/*", "refs/heads/a*", "refs/*/x", "refs/heads/**" }) |name| {
        const ours = checkRefFormat(name, .{ .pattern = true });
        const theirs = if (repo.exec(io, &.{ "check-ref-format", "--refspec-pattern", name })) true else |_| false;
        try testing.expectEqual(theirs, ours);
    }
}

test "fuzz: any bytes are a refspec or a named error" {
    try testing.fuzz({}, fuzzParse, .{});
}

fn fuzzParse(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [256]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    const gpa = testing.allocator;
    for ([_]Direction{ .fetch, .push }) |direction| {
        const spec = Refspec.parse(input, direction) catch |err| switch (err) {
            error.InvalidRefspec => continue,
        };
        // A name a pattern maps onto its destination maps back onto itself:
        // the star stands for the same text on both sides.
        if (spec.pattern and !spec.negative) {
            for ([_][]const u8{ "refs/heads/probe", input }) |probe| {
                const dst = (try spec.mapSource(gpa, probe)) orelse continue;
                defer gpa.free(dst);
                const src = (try spec.mapDestination(gpa, dst)) orelse return error.PatternDidNotRoundTrip;
                defer gpa.free(src);
                try testing.expectEqualStrings(probe, src);
            }
        }
        _ = spec.matchesSource(input);
        _ = excluded(&.{spec}, input);
    }
}
