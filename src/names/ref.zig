//! What a ref may be named, and which names git treats apart: one home for
//! git's `check_refname_format` and `refname_is_safe`, the classes of names
//! a ref store routes differently (root refs, the two special refs, the
//! per-worktree refs), the names that reach another worktree's refs, and
//! the name of every root ref git's commands write.
//!
//! A name is checked differently by what is done with it, as git checks it:
//! a ref is written only under a name `checkFormat` takes, while a deletion
//! needs only `isSafe`, which is what lets a ref with a bad name, found in
//! a listing, be removed.

const testgit = @import("../testing/git.zig");
const std = @import("std");
const builtin = @import("builtin");

/// What `checkFormat` takes beyond a full ref name: git's
/// `REFNAME_ALLOW_ONELEVEL` and `REFNAME_REFSPEC_PATTERN`.
pub const Flags = struct {
    /// A name of one component, such as `HEAD` or `main`.
    allow_onelevel: bool = false,
    /// One `*` anywhere, as a refspec pattern holds it.
    pattern: bool = false,
};

/// git's `check_refname_format`: whether `name` may be given to a ref.
///
/// No component may be empty, begin with `.`, end with `.lock`, or hold
/// `..`, `@{`, a control character, a space, `~`, `^`, `:`, `?`, `[`, `\`,
/// or -- past the one a pattern may hold -- `*`. The whole may not be `@`,
/// end with `.`, or, unless `allow_onelevel`, be a single component.
pub fn checkFormat(name: []const u8, flags: Flags) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "@")) return false;
    var stars_left: u8 = if (flags.pattern) 1 else 0;
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
    if (!flags.allow_onelevel and components < 2) return false;
    return true;
}

/// git's `refname_is_safe`: whether `name` names a file inside the ref
/// directories, which is all a deletion asks of a name. Under `refs/`
/// that is a path with no empty, `.` or `..` component; elsewhere it is
/// capitals and underscores alone, a root ref's spelling. A name
/// `checkFormat` refuses can still be safe: `refs/heads/a..b`,
/// `refs/heads/x.lock`.
pub fn isSafe(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "refs/")) {
        const rest = name["refs/".len..];
        if (rest.len == 0) return false;
        var it = std.mem.splitScalar(u8, rest, '/');
        while (it.next()) |component| {
            if (component.len == 0) return false;
            if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
            // A separator to the filesystem there, which git's
            // `normalize_path_copy` folds into a `/`.
            if (builtin.target.os.tag == .windows and std.mem.findScalar(u8, component, '\\') != null) return false;
        }
        return true;
    }
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isUpper(c) and c != '_') return false;
    }
    return true;
}

/// git's `is_root_ref_syntax`: capitals, `-` and `_`, and nothing else --
/// the spelling of `HEAD` and of every root ref.
pub fn isRootRefSyntax(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isUpper(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// git's `is_root_ref`: `HEAD`, a name in root-ref syntax ending `_HEAD`,
/// or one of the few that do not, and never one of the special refs.
pub fn isRootRef(name: []const u8) bool {
    if (!isRootRefSyntax(name) or isSpecial(name)) return false;
    if (std.mem.endsWith(u8, name, "_HEAD")) return true;
    for (irregular_root_refs) |irregular| {
        if (std.mem.eql(u8, name, irregular)) return true;
    }
    return false;
}

/// The root refs whose names do not end `_HEAD`, `HEAD` itself among them:
/// git's `irregular_root_refs`.
const irregular_root_refs = [_][]const u8{ "HEAD", "AUTO_MERGE", "BISECT_EXPECTED_REV", "NOTES_MERGE_PARTIAL", "NOTES_MERGE_REF", "MERGE_AUTOSTASH" };

/// git's `is_special_ref`: `FETCH_HEAD` and `MERGE_HEAD`, which hold more
/// than one object name and so are files in the git directory whatever
/// the ref format.
pub fn isSpecial(name: []const u8) bool {
    return Special.of(name) != null;
}

/// git's `is_per_worktree_ref`: the refs under `refs/` that each worktree
/// keeps for itself.
pub fn isPerWorktree(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "refs/bisect/") or
        std.mem.startsWith(u8, name, "refs/worktree/") or
        std.mem.startsWith(u8, name, "refs/rewritten/");
}

/// Which worktree's refs a name reaches, from git's `parse_worktree_ref`.
pub const WorktreeRef = struct {
    owner: Owner,
    /// For `.other`, the worktree's id: its directory under `worktrees/`.
    /// Empty otherwise. Borrowed from the name.
    id: []const u8 = "",
    /// The name in the worktree it reaches: the name itself for `.current`
    /// and `.shared`, and what follows the prefix for the others. Borrowed
    /// from the name.
    bare: []const u8,

    pub const Owner = enum {
        /// The worktree the store was opened in: `HEAD`, the root refs and
        /// the per-worktree refs under `refs/`.
        current,
        /// Every worktree's: the rest of `refs/`.
        shared,
        /// The main worktree's own, spelled `main-worktree/<name>`.
        main,
        /// A linked worktree's own, spelled `worktrees/<id>/<name>`.
        other,
    };
};

/// git's `parse_worktree_ref`. `main-worktree/HEAD` is the main worktree's
/// `HEAD` from any worktree, and `worktrees/<id>/refs/bisect/bad` that
/// linked worktree's bisection ref; a prefix in front of a name no
/// worktree keeps for itself is part of a shared ref's name.
/// `worktrees/<id>` with nothing after it reaches that worktree with an
/// empty `bare`, which names no ref.
pub fn parseWorktreeRef(name: []const u8) WorktreeRef {
    if (std.mem.startsWith(u8, name, "worktrees/")) {
        const rest = name["worktrees/".len..];
        const slash = std.mem.findScalar(u8, rest, '/') orelse
            return .{ .owner = .other, .id = rest, .bare = "" };
        const bare = rest[slash + 1 ..];
        if (isCurrentWorktree(bare)) return .{ .owner = .other, .id = rest[0..slash], .bare = bare };
    }
    if (std.mem.startsWith(u8, name, "main-worktree/")) {
        const bare = name["main-worktree/".len..];
        if (isCurrentWorktree(bare)) return .{ .owner = .main, .bare = bare };
    }
    if (isCurrentWorktree(name)) return .{ .owner = .current, .bare = name };
    return .{ .owner = .shared, .bare = name };
}

/// git's `is_current_worktree_ref`: a name each worktree keeps for itself,
/// `HEAD` and the root refs among them, which a linked worktree's store
/// finds in its own git directory.
pub fn isCurrentWorktree(name: []const u8) bool {
    return isRootRefSyntax(name) or isPerWorktree(name);
}

/// The root refs relic's commands write, each always written, read and
/// removed as itself and never through what it might name: git's
/// `REF_NO_DEREF`.
pub const Root = enum {
    /// Where `HEAD` was before a merge, a reset, a rebase or `am`.
    orig_head,
    /// The commit a stopped cherry-pick is picking.
    cherry_pick_head,
    /// The commit a stopped revert is reverting.
    revert_head,
    /// The commit a stopped rebase or `am` is applying.
    rebase_head,
    /// The tree a conflicted merge wrote, conflicts and all.
    auto_merge,
    /// Where a bisection without a checkout stands.
    bisect_head,
    /// The commit a bisection checked out last.
    bisect_expected_rev,
    /// The partial result of a manual notes merge.
    notes_merge_partial,
    /// The notes ref a manual notes merge is merging into.
    notes_merge_ref,

    /// The ref's name as git spells it.
    pub fn name(root: Root) []const u8 {
        return switch (root) {
            .orig_head => "ORIG_HEAD",
            .cherry_pick_head => "CHERRY_PICK_HEAD",
            .revert_head => "REVERT_HEAD",
            .rebase_head => "REBASE_HEAD",
            .auto_merge => "AUTO_MERGE",
            .bisect_head => "BISECT_HEAD",
            .bisect_expected_rev => "BISECT_EXPECTED_REV",
            .notes_merge_partial => "NOTES_MERGE_PARTIAL",
            .notes_merge_ref => "NOTES_MERGE_REF",
        };
    }
};

/// The special refs: files in the git directory in either ref format,
/// never written by a ref transaction.
pub const Special = enum {
    /// What the last fetch fetched, a line per ref, merge candidates first.
    fetch_head,
    /// The heads a stopped merge is merging, one per line.
    merge_head,

    /// The ref's name as git spells it, which is also its file's.
    pub fn name(special: Special) []const u8 {
        return switch (special) {
            .fetch_head => "FETCH_HEAD",
            .merge_head => "MERGE_HEAD",
        };
    }

    /// The special ref named `text`, or `null`.
    pub fn of(text: []const u8) ?Special {
        inline for (comptime std.enums.values(Special)) |special| {
            if (std.mem.eql(u8, text, special.name())) return special;
        }
        return null;
    }
};

const testing = std.testing;

test "a ref name follows check_refname_format, flag by flag" {
    try testing.expect(checkFormat("refs/heads/main", .{}));
    try testing.expect(!checkFormat("main", .{}));
    try testing.expect(checkFormat("main", .{ .allow_onelevel = true }));
    try testing.expect(checkFormat("refs/heads/*", .{ .pattern = true }));
    try testing.expect(checkFormat("refs/heads/a*b", .{ .pattern = true }));
    try testing.expect(!checkFormat("refs/*/a*b", .{ .pattern = true }));
    try testing.expect(!checkFormat("refs/heads/*", .{}));
    for ([_][]const u8{
        "refs/heads/.x", "refs/heads/x.",  "refs/heads/x.lock", "refs//heads",
        "refs/heads/",   "/refs/heads",    "refs/heads/a@{b",   "refs/heads/a b",
        "refs/heads/a~", "refs/heads/a^b", "refs/heads/a:b",    "refs/heads/a?",
        "refs/heads/a[", "refs/heads/a\\", "@",                 "refs/heads/a..b",
        "",
    }) |name| {
        try testing.expect(!checkFormat(name, .{ .allow_onelevel = true }));
    }
}

test "a ref name is checked as git check-ref-format checks it, under every flag" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    repo.report_failures = false;
    const names = [_][]const u8{
        "refs/heads/main",     "refs/heads/a.b",       "refs/heads/a..b", "refs/heads/.a",
        "refs/heads/a.lock",   "refs/heads/a@b",       "refs/heads/a@{b", "refs/tags/v1.0",
        "refs/heads/-dash",    "refs/heads/a/b/c",     "refs/heads/a//b", "refs/heads/trailing.",
        "refs/x",
        "refs/heads/emoji-é",
        "refs/heads/q?",       "refs/heads/@",         "HEAD",            "main",
        "@",                   "ORIG_HEAD",            "refs/heads/*",    "refs/heads/a*",
        "refs/*/x",            "refs/heads/**",        "*",               "refs/heads/a*b*",
        "refs/heads/a.lock/b", "refs/heads/a{b",       "refs/heads/a@",   "refs/heads/@{",
        "refs/heads/x\x7f",    "refs/heads/tab\there", "a/.b",            "refs/heads/a.",
        "refs/heads/.lock",    "refs/heads/lock",      "refs/heads/a]b",  "refs/heads/a!b",
        "refs/heads/a\"b",     "refs/heads/a#b",       "refs/heads/a%b",  "refs/heads/a&b",
        "refs/heads/a'b",      "refs/heads/a(b)",      "refs/heads/a+b",  "refs/heads/a,b",
        "refs/heads/a;b",      "refs/heads/a<b>",      "refs/heads/a=b",  "refs/heads/a`b",
        "refs/heads/a|b",      "refs/heads/a}b",       "refs/heads/a$b",  "x/",
        "refs/heads/a/",       "foo",
    };
    const combinations = [_]struct { flags: Flags, args: []const []const u8 }{
        .{ .flags = .{}, .args = &.{} },
        .{ .flags = .{ .allow_onelevel = true }, .args = &.{"--allow-onelevel"} },
        .{ .flags = .{ .pattern = true }, .args = &.{"--refspec-pattern"} },
        .{ .flags = .{ .allow_onelevel = true, .pattern = true }, .args = &.{ "--allow-onelevel", "--refspec-pattern" } },
    };
    for (combinations) |combination| {
        for (names) |name| {
            var argv: [4][]const u8 = undefined;
            argv[0] = "check-ref-format";
            for (combination.args, 1..) |arg, i| argv[i] = arg;
            argv[combination.args.len + 1] = name;
            const theirs = if (repo.exec(io, argv[0 .. combination.args.len + 2])) true else |_| false;
            testing.expectEqual(theirs, checkFormat(name, combination.flags)) catch |err| {
                std.debug.print("check-ref-format (onelevel {}, pattern {}) {s}\n", .{ combination.flags.allow_onelevel, combination.flags.pattern, name });
                return err;
            };
        }
    }
}

test "a name is safe to delete when it stays inside the ref directories" {
    for ([_][]const u8{ "refs/heads/main", "refs/heads/a..b", "refs/heads/x.lock", "refs/heads/a b", "HEAD", "ORIG_HEAD", "A_B" }) |name| {
        try testing.expect(isSafe(name));
    }
    for ([_][]const u8{ "refs/", "refs//x", "refs/x/", "refs/../x", "refs/a/./b", "refs/a/..", "", "head", "A-B", "x/y", "../refs/heads/x" }) |name| {
        try testing.expect(!isSafe(name));
    }
}

test "root refs and special refs are told apart as git tells them" {
    for ([_][]const u8{ "HEAD", "ORIG_HEAD", "CHERRY_PICK_HEAD", "AUTO_MERGE", "BISECT_EXPECTED_REV", "NOTES_MERGE_PARTIAL", "NOTES_MERGE_REF", "MERGE_AUTOSTASH", "X-Y_HEAD" }) |name| {
        try testing.expect(isRootRef(name));
    }
    for ([_][]const u8{ "FETCH_HEAD", "MERGE_HEAD", "MERGE_MSG", "head", "refs/heads/x", "", "ORIG_HEAD/x" }) |name| {
        try testing.expect(!isRootRef(name));
    }
    try testing.expect(isSpecial("FETCH_HEAD") and isSpecial("MERGE_HEAD") and !isSpecial("ORIG_HEAD"));
    try testing.expect(isRootRefSyntax("MERGE_MSG") and !isRootRefSyntax("Merge") and !isRootRefSyntax(""));
    inline for (comptime std.enums.values(Root)) |root| {
        try testing.expect(isRootRef(root.name()));
        try testing.expect(checkFormat(root.name(), .{ .allow_onelevel = true }));
    }
    inline for (comptime std.enums.values(Special)) |special| {
        try testing.expectEqual(special, Special.of(special.name()).?);
    }
}

test "a worktree-qualified name reaches the worktree git's parse_worktree_ref names" {
    const cases = [_]struct { name: []const u8, owner: WorktreeRef.Owner, id: []const u8, bare: []const u8 }{
        .{ .name = "HEAD", .owner = .current, .id = "", .bare = "HEAD" },
        .{ .name = "ORIG_HEAD", .owner = .current, .id = "", .bare = "ORIG_HEAD" },
        .{ .name = "refs/bisect/bad", .owner = .current, .id = "", .bare = "refs/bisect/bad" },
        .{ .name = "refs/worktree/x", .owner = .current, .id = "", .bare = "refs/worktree/x" },
        .{ .name = "refs/rewritten/l", .owner = .current, .id = "", .bare = "refs/rewritten/l" },
        .{ .name = "refs/heads/main", .owner = .shared, .id = "", .bare = "refs/heads/main" },
        .{ .name = "main-worktree/HEAD", .owner = .main, .id = "", .bare = "HEAD" },
        .{ .name = "main-worktree/refs/bisect/bad", .owner = .main, .id = "", .bare = "refs/bisect/bad" },
        .{ .name = "main-worktree/refs/heads/x", .owner = .shared, .id = "", .bare = "main-worktree/refs/heads/x" },
        .{ .name = "worktrees/wt/HEAD", .owner = .other, .id = "wt", .bare = "HEAD" },
        .{ .name = "worktrees/wt/refs/worktree/x", .owner = .other, .id = "wt", .bare = "refs/worktree/x" },
        .{ .name = "worktrees/wt/refs/heads/x", .owner = .shared, .id = "", .bare = "worktrees/wt/refs/heads/x" },
        .{ .name = "worktrees/wt", .owner = .other, .id = "wt", .bare = "" },
    };
    for (cases) |case| {
        const parsed = parseWorktreeRef(case.name);
        try testing.expectEqual(case.owner, parsed.owner);
        try testing.expectEqualStrings(case.id, parsed.id);
        try testing.expectEqualStrings(case.bare, parsed.bare);
    }
}

test "fuzz: any bytes answer without a crash, and a valid name is safe" {
    try testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [256]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    const valid = checkFormat(input, .{});
    _ = checkFormat(input, .{ .allow_onelevel = true, .pattern = true });
    // A name a ref may be given under `refs/` is one a deletion may name.
    if (valid and std.mem.startsWith(u8, input, "refs/")) try testing.expect(isSafe(input));
    const parsed = parseWorktreeRef(input);
    try testing.expect(parsed.bare.len <= input.len);
    _ = isRootRef(input);
}

/// The ref whose log records the stash stack.
pub const stash = "refs/stash";
