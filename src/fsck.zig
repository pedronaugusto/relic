//! What git's `fsck` finds wrong with one object's bytes.
//!
//! An object that arrives over the wire was written by someone else, and a
//! well-formed name says nothing about well-formed content: a tree whose
//! entries are out of order, or name `.git`, or a commit with two authors,
//! hashes as happily as any other. git checks each received object when
//! `transfer.fsckObjects` asks; relic checks every one it receives, and a
//! failure is a refusal that names the problem with git's own message id.
//!
//! The checks are the ones git reports as errors, taken from `fsck.c`, plus
//! three of its warnings that are about safety rather than style: a tree
//! entry named `.`, `..` or `.git` in any spelling is a path that escapes a
//! working tree on checkout, and relic refuses to check one out anyway.
//! Style warnings — a zero-padded mode, a tag with no tagger — are not
//! reported, because old and perfectly good repositories carry them.

const std = @import("std");

const hash = @import("hash.zig");
const object = @import("object.zig");
const safepath = @import("safepath.zig");

const Oid = hash.Oid;
const Kind = hash.Kind;

/// One problem, named as git's `fsck.<msg-id>` names it.
pub const Problem = enum {
    // Any object with headers.
    nul_in_header,
    unterminated_header,
    // Commits.
    missing_tree,
    bad_tree_sha1,
    bad_parent_sha1,
    missing_author,
    multiple_authors,
    missing_committer,
    // Identities, in a commit or a tag.
    missing_name_before_email,
    bad_name,
    missing_email,
    missing_space_before_email,
    bad_email,
    missing_space_before_date,
    zero_padded_date,
    bad_date_overflow,
    bad_date,
    bad_timezone,
    // Trees.
    bad_tree,
    tree_not_sorted,
    duplicate_entries,
    has_dot,
    has_dotdot,
    has_dotgit,
    // Tags.
    missing_object,
    bad_object_sha1,
    missing_type_entry,
    missing_type,
    bad_type,
    missing_tag_entry,
    missing_tag,

    /// git's message id: `treeNotSorted`, `badTimezone`, and so on, which
    /// is what `fsck.<msg-id>` configuration and git's own messages use.
    pub fn id(problem: Problem) []const u8 {
        return switch (problem) {
            .nul_in_header => "nulInHeader",
            .unterminated_header => "unterminatedHeader",
            .missing_tree => "missingTree",
            .bad_tree_sha1 => "badTreeSha1",
            .bad_parent_sha1 => "badParentSha1",
            .missing_author => "missingAuthor",
            .multiple_authors => "multipleAuthors",
            .missing_committer => "missingCommitter",
            .missing_name_before_email => "missingNameBeforeEmail",
            .bad_name => "badName",
            .missing_email => "missingEmail",
            .missing_space_before_email => "missingSpaceBeforeEmail",
            .bad_email => "badEmail",
            .missing_space_before_date => "missingSpaceBeforeDate",
            .zero_padded_date => "zeroPaddedDate",
            .bad_date_overflow => "badDateOverflow",
            .bad_date => "badDate",
            .bad_timezone => "badTimezone",
            .bad_tree => "badTree",
            .tree_not_sorted => "treeNotSorted",
            .duplicate_entries => "duplicateEntries",
            .has_dot => "hasDot",
            .has_dotdot => "hasDotdot",
            .has_dotgit => "hasDotgit",
            .missing_object => "missingObject",
            .bad_object_sha1 => "badObjectSha1",
            .missing_type_entry => "missingTypeEntry",
            .missing_type => "missingType",
            .bad_type => "badType",
            .missing_tag_entry => "missingTagEntry",
            .missing_tag => "missingTag",
        };
    }
};

/// The first problem with an object of type `t` whose content is `bytes`,
/// or `null` when git's checks find none. A blob is never a problem.
pub fn check(kind: Kind, t: object.Type, bytes: []const u8) ?Problem {
    return switch (t) {
        .blob => null,
        .tree => checkTree(kind, bytes),
        .commit => checkCommit(kind, bytes),
        .tag => checkTag(kind, bytes),
    };
}

fn checkTree(kind: Kind, bytes: []const u8) ?Problem {
    var it = object.Tree.parse(kind, bytes).iterate();
    var previous: ?object.Tree.Entry = null;
    // A blob `a` and a tree `a` sort apart — `a`, `a.c`, `a/` — so a
    // duplicate is not always the entry before; git keeps the names it may
    // still meet, and the ones still pending here are the entries that
    // were a prefix of the ones after them.
    var pending: [64][]const u8 = undefined;
    var pending_len: usize = 0;
    while (true) {
        const entry = (it.next() catch return .bad_tree) orelse break;
        if (safepath.checkComponent(entry.name, .stored)) |reason| switch (reason) {
            .dot_component => return if (entry.name.len == 1) .has_dot else .has_dotdot,
            .git_directory => return .has_dotgit,
            else => {},
        };
        if (previous) |prev| {
            switch (compareEntries(prev, entry)) {
                .lt => {},
                .eq => return .duplicate_entries,
                .gt => return .tree_not_sorted,
            }
        }
        // Names that are a strict prefix of this one followed by a byte
        // below `/` may still meet their twin further on.
        var kept: usize = 0;
        for (pending[0..pending_len]) |name| {
            if (std.mem.eql(u8, name, entry.name)) return .duplicate_entries;
            if (entry.name.len > name.len and std.mem.startsWith(u8, entry.name, name) and entry.name[name.len] < '/') {
                pending[kept] = name;
                kept += 1;
            }
        }
        pending_len = kept;
        if (pending_len < pending.len) {
            pending[pending_len] = entry.name;
            pending_len += 1;
        }
        previous = entry;
    }
    return null;
}

/// git's `base_name_compare`: names compared as if a tree's had a `/` on
/// the end, so `a.c` sorts before the tree `a` and `a0` after it.
fn compareEntries(a: object.Tree.Entry, b: object.Tree.Entry) std.math.Order {
    const len = @min(a.name.len, b.name.len);
    const common = std.mem.order(u8, a.name[0..len], b.name[0..len]);
    if (common != .eq) return common;
    const ca: u8 = if (a.name.len > len) a.name[len] else if (a.mode.isTree()) '/' else 0;
    const cb: u8 = if (b.name.len > len) b.name[len] else if (b.mode.isTree()) '/' else 0;
    if (ca == cb) return if (a.name.len == b.name.len) .eq else std.math.order(a.name.len, b.name.len);
    return std.math.order(ca, cb);
}

fn verifyHeaders(bytes: []const u8) ?Problem {
    for (bytes, 0..) |c, i| {
        switch (c) {
            0 => return .nul_in_header,
            '\n' => if (i + 1 < bytes.len and bytes[i + 1] == '\n') return null,
            else => {},
        }
    }
    // No blank line: no body, which is allowed, as long as the last header
    // line is terminated.
    if (bytes.len != 0 and bytes[bytes.len - 1] == '\n') return null;
    return .unterminated_header;
}

const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn skip(c: *Cursor, prefix: []const u8) bool {
        if (!std.mem.startsWith(u8, c.bytes[c.at..], prefix)) return false;
        c.at += prefix.len;
        return true;
    }

    /// An object name ending the line, and the line taken.
    fn oidLine(c: *Cursor, kind: Kind) bool {
        const hex_len = kind.hexLen();
        const rest = c.bytes[c.at..];
        if (rest.len < hex_len + 1 or rest[hex_len] != '\n') {
            c.skipLine();
            return false;
        }
        _ = Oid.parse(kind, rest[0..hex_len]) catch {
            c.skipLine();
            return false;
        };
        c.at += hex_len + 1;
        return true;
    }

    fn skipLine(c: *Cursor) void {
        const nl = std.mem.indexOfScalarPos(u8, c.bytes, c.at, '\n') orelse c.bytes.len;
        c.at = @min(nl + 1, c.bytes.len);
    }
};

fn checkCommit(kind: Kind, bytes: []const u8) ?Problem {
    if (verifyHeaders(bytes)) |problem| return problem;
    var c: Cursor = .{ .bytes = bytes };
    if (!c.skip("tree ")) return .missing_tree;
    if (!c.oidLine(kind)) return .bad_tree_sha1;
    while (c.skip("parent ")) {
        if (!c.oidLine(kind)) return .bad_parent_sha1;
    }
    var authors: usize = 0;
    while (c.skip("author ")) {
        authors += 1;
        if (checkIdent(&c)) |problem| return problem;
    }
    if (authors == 0) return .missing_author;
    if (authors > 1) return .multiple_authors;
    if (!c.skip("committer ")) return .missing_committer;
    if (checkIdent(&c)) |problem| return problem;
    return null;
}

fn checkTag(kind: Kind, bytes: []const u8) ?Problem {
    if (verifyHeaders(bytes)) |problem| return problem;
    var c: Cursor = .{ .bytes = bytes };
    if (!c.skip("object ")) return .missing_object;
    if (!c.oidLine(kind)) return .bad_object_sha1;
    if (!c.skip("type ")) return .missing_type_entry;
    const type_end = std.mem.indexOfScalarPos(u8, bytes, c.at, '\n') orelse return .missing_type;
    _ = object.Type.parse(bytes[c.at..type_end]) catch return .bad_type;
    c.at = type_end + 1;
    if (!c.skip("tag ")) return .missing_tag_entry;
    const tag_end = std.mem.indexOfScalarPos(u8, bytes, c.at, '\n') orelse return .missing_tag;
    c.at = tag_end + 1;
    // Early tags carry no tagger, which git reports only as information.
    if (c.skip("tagger ")) {
        if (checkIdent(&c)) |problem| return problem;
    }
    return null;
}

/// git's `fsck_ident`: `Name <email> <seconds> <±hhmm>` and a newline.
fn checkIdent(c: *Cursor) ?Problem {
    const bytes = c.bytes;
    const nl = std.mem.indexOfScalarPos(u8, bytes, c.at, '\n') orelse bytes.len;
    var p = c.at;
    c.at = @min(nl + 1, bytes.len);
    const end = nl;

    if (p < end and bytes[p] == '<') return .missing_name_before_email;
    while (true) : (p += 1) {
        if (p >= end) return .missing_email;
        if (bytes[p] == '>') return .bad_name;
        if (bytes[p] == '<') break;
    }
    if (bytes[p - 1] != ' ') return .missing_space_before_email;
    p += 1;
    while (true) : (p += 1) {
        if (p >= end or bytes[p] == '<') return .bad_email;
        if (bytes[p] == '>') break;
    }
    p += 1;
    if (p >= end or bytes[p] != ' ') return .missing_space_before_date;
    p += 1;
    if (p < end and bytes[p] == '0' and (p + 1 >= end or bytes[p + 1] != ' ')) return .zero_padded_date;
    const digits_start = p;
    while (p < end and std.ascii.isDigit(bytes[p])) p += 1;
    if (p == digits_start or p >= end or bytes[p] != ' ') return .bad_date;
    // git keeps a date in an unsigned 64-bit timestamp and refuses one past
    // what its date functions can hold.
    const seconds = std.fmt.parseInt(u64, bytes[digits_start..p], 10) catch return .bad_date_overflow;
    if (seconds > max_date) return .bad_date_overflow;
    p += 1;
    if (end - p != 5) return .bad_timezone;
    if (bytes[p] != '+' and bytes[p] != '-') return .bad_timezone;
    for (bytes[p + 1 .. p + 5]) |d| {
        if (!std.ascii.isDigit(d)) return .bad_timezone;
    }
    return null;
}

/// The largest date git's `date_overflows` lets through: a timestamp must
/// fit a signed 64-bit `time_t`.
const max_date: u64 = std.math.maxInt(i64);

const testing = std.testing;
const testgit = @import("testgit.zig");

const zero_hex = "0000000000000000000000000000000000000000";
const good_ident = "A U Thor <author@example.com> 1700000000 +0000";

test "a well-formed commit, tree and tag have no problem" {
    const commit = "tree " ++ zero_hex ++ "\nparent " ++ zero_hex ++ "\nauthor " ++ good_ident ++
        "\ncommitter " ++ good_ident ++ "\n\nmessage\n";
    try testing.expect(check(.sha1, .commit, commit) == null);
    const tag = "object " ++ zero_hex ++ "\ntype commit\ntag v1\ntagger " ++ good_ident ++ "\n\nv1\n";
    try testing.expect(check(.sha1, .tag, tag) == null);
    const tree = "100644 a.c\x00" ++ ("\x01" ** 20) ++ "40000 a\x00" ++ ("\x02" ** 20) ++ "100644 a0\x00" ++ ("\x03" ** 20);
    try testing.expect(check(.sha1, .tree, tree) == null);
    try testing.expect(check(.sha1, .blob, "\x00anything") == null);
}

test "each broken commit is named as git names it" {
    const Case = struct { bytes: []const u8, problem: Problem };
    const cases = [_]Case{
        .{ .bytes = "parent " ++ zero_hex ++ "\n", .problem = .missing_tree },
        .{ .bytes = "tree 123\n", .problem = .bad_tree_sha1 },
        .{ .bytes = "tree " ++ zero_hex ++ "\nparent xyz\n", .problem = .bad_parent_sha1 },
        .{ .bytes = "tree " ++ zero_hex ++ "\ncommitter " ++ good_ident ++ "\n", .problem = .missing_author },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor " ++ good_ident ++ "\nauthor " ++ good_ident ++ "\n", .problem = .multiple_authors },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor " ++ good_ident ++ "\n", .problem = .missing_committer },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor <a@b> 1 +0000\n", .problem = .missing_name_before_email },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A> <a@b> 1 +0000\n", .problem = .bad_name },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A 1 +0000\n", .problem = .missing_email },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A<a@b> 1 +0000\n", .problem = .missing_space_before_email },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b\n", .problem = .bad_email },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b>1 +0000\n", .problem = .missing_space_before_date },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 01 +0000\n", .problem = .zero_padded_date },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 99999999999999999999 +0000\n", .problem = .bad_date_overflow },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> x +0000\n", .problem = .bad_date },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 1 0000\n", .problem = .bad_timezone },
        .{ .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 1 +0000", .problem = .unterminated_header },
        .{ .bytes = "tree " ++ zero_hex ++ "\x00\n", .problem = .nul_in_header },
    };
    for (cases) |case| {
        try testing.expectEqual(@as(?Problem, case.problem), check(.sha1, .commit, case.bytes));
    }
}

test "each broken tag is named as git names it" {
    const Case = struct { bytes: []const u8, problem: Problem };
    const cases = [_]Case{
        .{ .bytes = "type commit\n", .problem = .missing_object },
        .{ .bytes = "object 12\n", .problem = .bad_object_sha1 },
        .{ .bytes = "object " ++ zero_hex ++ "\ntag v1\n", .problem = .missing_type_entry },
        .{ .bytes = "object " ++ zero_hex ++ "\ntype bogus\ntag v1\n", .problem = .bad_type },
        .{ .bytes = "object " ++ zero_hex ++ "\ntype commit\ntagger " ++ good_ident ++ "\n", .problem = .missing_tag_entry },
        .{ .bytes = "object " ++ zero_hex ++ "\ntype commit\ntag v1\ntagger A <a@b> 1 +00\n", .problem = .bad_timezone },
    };
    for (cases) |case| {
        try testing.expectEqual(@as(?Problem, case.problem), check(.sha1, .tag, case.bytes));
    }
    // A tag with no tagger is old, not broken.
    try testing.expect(check(.sha1, .tag, "object " ++ zero_hex ++ "\ntype commit\ntag v1\n\nold\n") == null);
}

test "a tree out of order, with a twin, or naming .git is refused by name" {
    const oid = "\x01" ** 20;
    try testing.expectEqual(@as(?Problem, .tree_not_sorted), check(.sha1, .tree, "100644 b\x00" ++ oid ++ "100644 a\x00" ++ oid));
    try testing.expectEqual(@as(?Problem, .duplicate_entries), check(.sha1, .tree, "100644 a\x00" ++ oid ++ "100644 a\x00" ++ oid));
    // The blob `a` and the tree `a` sort apart, with `a.c` between them.
    try testing.expectEqual(@as(?Problem, .duplicate_entries), check(.sha1, .tree, "100644 a\x00" ++ oid ++ "100644 a.c\x00" ++ oid ++ "40000 a\x00" ++ oid));
    try testing.expectEqual(@as(?Problem, .has_dotgit), check(.sha1, .tree, "40000 .git\x00" ++ oid));
    try testing.expectEqual(@as(?Problem, .has_dotgit), check(.sha1, .tree, "40000 .GIT\x00" ++ oid));
    try testing.expectEqual(@as(?Problem, .has_dotdot), check(.sha1, .tree, "40000 ..\x00" ++ oid));
    try testing.expectEqual(@as(?Problem, .has_dot), check(.sha1, .tree, "40000 .\x00" ++ oid));
    try testing.expectEqual(@as(?Problem, .bad_tree), check(.sha1, .tree, "100644 a\x00" ++ "\x01" ** 3));
    try testing.expectEqual(@as(?Problem, .bad_tree), check(.sha1, .tree, "999999 a\x00" ++ oid));
}

test "git refuses the same objects and names the same problem" {
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    const Case = struct { t: object.Type, bytes: []const u8, problem: Problem };
    const oid = "\x01" ** 20;
    const cases = [_]Case{
        .{ .t = .commit, .bytes = "tree 123\nauthor " ++ good_ident ++ "\n", .problem = .bad_tree_sha1 },
        .{ .t = .commit, .bytes = "tree " ++ zero_hex ++ "\nauthor " ++ good_ident ++ "\n\n", .problem = .missing_committer },
        .{ .t = .commit, .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 01 +0000\ncommitter " ++ good_ident ++ "\n\n", .problem = .zero_padded_date },
        .{ .t = .commit, .bytes = "tree " ++ zero_hex ++ "\nauthor A <a@b> 1 +00\ncommitter " ++ good_ident ++ "\n\n", .problem = .bad_timezone },
        .{ .t = .tag, .bytes = "object " ++ zero_hex ++ "\ntype bogus\ntag v1\n\n", .problem = .bad_type },
        .{ .t = .tag, .bytes = "object " ++ zero_hex ++ "\ntype commit\n\n", .problem = .missing_tag_entry },
        .{ .t = .tree, .bytes = "100644 b\x00" ++ oid ++ "100644 a\x00" ++ oid, .problem = .tree_not_sorted },
        .{ .t = .tree, .bytes = "100644 a\x00" ++ oid ++ "100644 a\x00" ++ oid, .problem = .duplicate_entries },
        .{ .t = .tree, .bytes = "40000 .git\x00" ++ oid, .problem = .has_dotgit },
    };
    for (cases) |case| {
        try testing.expectEqual(@as(?Problem, case.problem), check(.sha1, case.t, case.bytes));
        // `hash-object` without `--literally` runs git's fsck checks and
        // refuses, naming the message id on standard error.
        try repo.writeFile(io, "object", case.bytes);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, "git");
        try argv.appendSlice(gpa, repo.defaults);
        try argv.appendSlice(gpa, &.{ "hash-object", "-t", case.t.name(), "object" });
        const result = try std.process.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .dir = repo.dir }, .environ_map = repo.environMap() });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try testing.expect(result.term != .exited or result.term.exited != 0);
        if (std.mem.indexOf(u8, result.stderr, case.problem.id()) == null) {
            std.debug.print("git said: {s}\nexpected: {s}\n", .{ result.stderr, case.problem.id() });
            return error.TestUnexpectedResult;
        }
    }
}

test "fuzz: any bytes are a verdict, never a crash" {
    try testing.fuzz({}, fuzzCheck, .{});
}

fn fuzzCheck(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [1024]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    for ([_]object.Type{ .blob, .tree, .commit, .tag }) |t| {
        _ = check(.sha1, t, input);
        _ = check(.sha256, t, input);
    }
}
