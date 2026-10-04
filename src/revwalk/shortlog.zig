//! `git shortlog`: commits grouped by who made them, as git groups, sorts
//! and prints them.
//!
//! A shortlog is fed commits in the order a walk gives them -- `revwalk.Walk`
//! gives `git rev-list`'s -- and prints each group's subjects oldest first,
//! the groups in byte order of their names, or with `numbered` by how many
//! commits each has, ties kept in that order. A group is the author's name
//! as the mailmap shows it (`%aN`), with `email` its email too (`%aN <%aE>`);
//! or the committer's; or the value of a trailer, read as an identity and
//! mapped when it is one. Asked for more than one, a commit is counted once
//! in a group however many of its people or trailers name it.
//!
//! A subject is the commit's `%s` with any `[PATCH...]` prefix taken off;
//! `wrap` folds it as `-w` does, counting columns as git's own table does.
//! `--group=format:` and a format given with `%` are refused by name, as is
//! a message in an encoding other than UTF-8, which git would convert first,
//! and a trailer group in a repository that configures `trailer.*`, which
//! changes what git reads as one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const odb_mod = @import("../odb.zig");
const message = @import("../commit/message.zig");
const mailmap_mod = @import("mailmap.zig");
const unicodewidth = @import("../unicodewidth.zig");
const config_mod = @import("../config.zig");

const Oid = hash.Oid;

/// What a commit is grouped by: `--group`.
pub const Group = union(enum) {
    /// `--group=author`, the default.
    author,
    /// `--group=committer`, `-c`.
    committer,
    /// `--group=trailer:<key>`; the key is matched without case.
    trailer: []const u8,
    /// `--group=format:<format>`: refused by name.
    format: []const u8,
};

/// `-w<width>,<indent1>,<indent2>`.
pub const Wrap = struct {
    width: u32 = 76,
    indent1: u32 = 6,
    indent2: u32 = 9,
};

/// How a shortlog groups and prints.
pub const Options = struct {
    /// Empty is `author`.
    groups: []const Group = &.{},
    /// `-s`: a count per group and no subjects.
    summary: bool = false,
    /// `-n`: the largest group first.
    numbered: bool = false,
    /// `-e`: each person's email after their name.
    email: bool = false,
    /// `-w`: subjects folded to a width.
    wrap: ?Wrap = null,
    /// Who people are, as `Mailmap.load` reads it. `null` maps nobody.
    mailmap: ?*const mailmap_mod.Mailmap = null,
    /// `core.commentChar`, which decides where a message's trailer block
    /// ends.
    comment: []const u8 = "#",
    /// Whether the repository configures `trailer.*`; a trailer group is
    /// then refused, since git would read trailers as configured.
    trailer_config: bool = false,
};

/// Errors from a shortlog.
pub const Error = error{
    /// `--group=format:`, which needs git's pretty formats.
    FormatGroupUnsupported,
    /// A commit whose `encoding` header names something other than UTF-8.
    EncodingUnsupported,
    /// A trailer group in a repository whose `trailer.*` settings change
    /// what a trailer is.
    TrailerConfigUnsupported,
    /// A `-w` whose width is no wider than an indent: git's usage error.
    InvalidWrap,
} || Allocator.Error || odb_mod.Error || object.ParseError;

const Record = struct {
    count: usize = 0,
    subjects: std.ArrayList([]const u8) = .empty,
};

/// Commits being grouped.
pub const Shortlog = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    options: Options,
    trailer_keys: []const []const u8,
    author: bool,
    committer: bool,
    dedup: bool,
    records: std.StringArrayHashMapUnmanaged(Record) = .empty,

    /// A shortlog with nothing in it yet.
    pub fn init(gpa: Allocator, options: Options) Error!Shortlog {
        var author = false;
        var committer = false;
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(gpa);
        for (options.groups) |group| switch (group) {
            .author => author = true,
            .committer => committer = true,
            .trailer => |key| try keys.append(gpa, key),
            .format => return error.FormatGroupUnsupported,
        };
        if (options.groups.len == 0) author = true;
        if (keys.items.len != 0 and options.trailer_config) return error.TrailerConfigUnsupported;
        if (options.wrap) |w| {
            if (w.width != 0 and ((w.indent1 != 0 and w.width <= w.indent1) or (w.indent2 != 0 and w.width <= w.indent2)))
                return error.InvalidWrap;
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const owned_keys = try arena.allocator().dupe([]const u8, keys.items);
        const kinds = @as(usize, @intFromBool(author)) + @intFromBool(committer) + @intFromBool(owned_keys.len != 0);
        return .{
            .gpa = gpa,
            .arena = arena,
            .options = options,
            .trailer_keys = owned_keys,
            .author = author,
            .committer = committer,
            // `shortlog_needs_dedup`: more than one kind of group, or any
            // trailer.
            .dedup = kinds > 1 or owned_keys.len != 0,
        };
    }

    /// Release everything.
    pub fn deinit(s: *Shortlog) void {
        for (s.records.values()) |*r| r.subjects.deinit(s.gpa);
        s.records.deinit(s.gpa);
        s.arena.deinit();
        s.* = undefined;
    }

    /// Read the commit `oid` from `db` and add it.
    pub fn add(s: *Shortlog, io: Io, db: *odb_mod.Odb, oid: Oid) Error!void {
        const found = try db.read(io, oid);
        defer db.allocator().free(found.bytes);
        if (found.type != .commit) return error.UnexpectedObjectType;
        var commit = try object.Commit.parse(s.gpa, db.objectFormat(), found.bytes);
        defer commit.deinit();
        try s.addCommit(&commit);
    }

    /// `shortlog_add_commit`: add a commit already read.
    pub fn addCommit(s: *Shortlog, commit: *const object.Commit) Error!void {
        if (commit.encoding) |enc| {
            if (!std.ascii.eqlIgnoreCase(enc, "utf-8") and !std.ascii.eqlIgnoreCase(enc, "utf8"))
                return error.EncodingUnsupported;
        }
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        const oneline: []const u8 = if (s.options.summary) "" else blk: {
            const subject = try message.onelineSubject(a, commit.message);
            break :blk if (subject.len == 0) "<none>" else subject;
        };

        var seen: std.StringHashMapUnmanaged(void) = .empty;
        if (s.trailer_keys.len != 0) {
            // git reads trailers from the commit buffer at its first blank
            // line, the blank line itself included, so the title paragraph
            // can be a trailer block of its own.
            const body = try std.mem.concat(a, u8, &.{ "\n\n", commit.message });
            for (try message.trailers(a, body, s.options.comment)) |t| {
                if (!s.wantsKey(t.key)) continue;
                const value = try s.identOf(a, t.value) orelse t.value;
                if ((try seen.getOrPut(a, value)).found_existing) continue;
                try s.insert(value, oneline);
            }
        }
        if (s.author) try s.insertPerson(a, &seen, commit.author, oneline);
        if (s.committer) try s.insertPerson(a, &seen, commit.committer, oneline);
    }

    fn wantsKey(s: *const Shortlog, key: []const u8) bool {
        for (s.trailer_keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return true;
        return false;
    }

    fn insertPerson(s: *Shortlog, a: Allocator, seen: *std.StringHashMapUnmanaged(void), who: object.Signature, oneline: []const u8) Error!void {
        const text = try s.formatPerson(a, trimName(who.name), who.email);
        if (s.dedup and (try seen.getOrPut(a, text)).found_existing) return;
        try s.insert(text, oneline);
    }

    /// `%aN` or `%aN <%aE>`.
    fn formatPerson(s: *const Shortlog, a: Allocator, name: []const u8, email: []const u8) Allocator.Error![]const u8 {
        const shown = if (s.options.mailmap) |m| m.map(name, email) else mailmap_mod.Identity{ .name = name, .email = email };
        if (s.options.email) return std.fmt.allocPrint(a, "{s} <{s}>", .{ shown.name, shown.email });
        return a.dupe(u8, shown.name);
    }

    /// `parse_ident`: a trailer value that reads as `Name <email>` is shown
    /// as a person is, and anything else as it is written.
    fn identOf(s: *const Shortlog, a: Allocator, value: []const u8) Allocator.Error!?[]const u8 {
        const lt = std.mem.indexOfScalar(u8, value, '<') orelse return null;
        const gt = std.mem.indexOfScalarPos(u8, value, lt + 1, '>') orelse return null;
        return try s.formatPerson(a, trimName(value[0..lt]), value[lt + 1 .. gt]);
    }

    /// `insert_one_record`.
    fn insert(s: *Shortlog, ident: []const u8, oneline_in: []const u8) Error!void {
        const slot = try s.records.getOrPut(s.gpa, ident);
        if (!slot.found_existing) {
            slot.key_ptr.* = try s.arena.allocator().dupe(u8, ident);
            slot.value_ptr.* = .{};
        }
        const record = slot.value_ptr;
        record.count += 1;
        if (s.options.summary) return;

        var oneline = oneline_in;
        while (oneline.len > 0 and isSpace(oneline[0])) oneline = oneline[1..];
        const eol = std.mem.indexOfScalar(u8, oneline, '\n') orelse oneline.len;
        if (std.mem.startsWith(u8, oneline, "[PATCH")) {
            if (std.mem.indexOfScalar(u8, oneline, ']')) |eob| {
                if (eob < eol) oneline = oneline[eob + 1 ..];
            }
        }
        while (oneline.len > 0 and isSpace(oneline[0]) and oneline[0] != '\n') oneline = oneline[1..];
        const subject = try message.onelineSubject(s.arena.allocator(), oneline);
        try record.subjects.append(s.gpa, subject);
    }

    /// `shortlog_output`.
    pub fn write(s: *Shortlog, w: *Io.Writer) (Io.Writer.Error || Allocator.Error)!void {
        const Sort = struct {
            keys: []const []const u8,
            values: []const Record,
            numbered: bool,
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                if (ctx.numbered and ctx.values[a].count != ctx.values[b].count)
                    return ctx.values[a].count > ctx.values[b].count;
                return std.mem.order(u8, ctx.keys[a], ctx.keys[b]) == .lt;
            }
        };
        const order = try s.gpa.alloc(usize, s.records.count());
        defer s.gpa.free(order);
        for (order, 0..) |*o, i| o.* = i;
        std.sort.pdq(usize, order, Sort{ .keys = s.records.keys(), .values = s.records.values(), .numbered = s.options.numbered }, Sort.lessThan);

        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(s.gpa);
        for (order) |i| {
            const ident = s.records.keys()[i];
            const record = &s.records.values()[i];
            if (s.options.summary) {
                try w.print("{d: >6}\t{s}\n", .{ record.count, ident });
                continue;
            }
            try w.print("{s} ({d}):\n", .{ ident, record.subjects.items.len });
            var j = record.subjects.items.len;
            while (j > 0) {
                j -= 1;
                const msg = record.subjects.items[j];
                if (s.options.wrap) |opt| {
                    wrapped.clearRetainingCapacity();
                    try addWrappedText(s.gpa, &wrapped, msg, @intCast(opt.indent1), @intCast(opt.indent2), @intCast(opt.width));
                    try w.writeAll(wrapped.items);
                    try w.writeByte('\n');
                } else {
                    try w.print("      {s}\n", .{msg});
                }
            }
            try w.writeByte('\n');
        }
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// `split_ident_line`'s name: up to the `<`, without whitespace after it.
fn trimName(name: []const u8) []const u8 {
    var end = name.len;
    while (end > 0 and isSpace(name[end - 1])) end -= 1;
    return name[0..end];
}

/// `display_mode_esc_sequence_len`: an SGR escape, `ESC [ <digits;> m`.
fn escapeLength(text: []const u8, at: usize) usize {
    var p = at;
    if (p >= text.len or text[p] != 0x1b) return 0;
    p += 1;
    if (p >= text.len or text[p] != '[') return 0;
    p += 1;
    while (p < text.len and (std.ascii.isDigit(text[p]) or text[p] == ';')) p += 1;
    if (p >= text.len or text[p] != 'm') return 0;
    return p + 1 - at;
}

/// `strbuf_add_wrapped_text`: `text` folded at spaces to `width` columns,
/// the first line indented by `indent1` and the rest by `indent2`. A text
/// that is not UTF-8 is counted a byte to a column, as git counts it.
pub fn addWrappedText(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8, indent1: i32, indent2: i32, width: i32) Allocator.Error!void {
    if (width <= 0) {
        // `strbuf_add_indented_text`.
        var indent: usize = @intCast(@max(indent1, 0));
        var rest = text;
        while (rest.len > 0) {
            const eol = if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| nl + 1 else rest.len;
            try out.appendNTimes(gpa, ' ', indent);
            try out.appendSlice(gpa, rest[0..eol]);
            rest = rest[eol..];
            indent = @intCast(@max(indent2, 0));
        }
        return;
    }
    const orig_len = out.items.len;
    var assume_utf8 = true;
    const at = struct {
        fn f(t: []const u8, i: usize) u8 {
            return if (i < t.len) t[i] else 0;
        }
    }.f;
    retry: while (true) {
        var i: usize = 0;
        var bol: usize = 0;
        var indent: i32 = indent1;
        var w: i32 = indent;
        var space: ?usize = null;
        if (indent < 0) {
            w = -indent;
            space = 0;
        }
        while (true) {
            while (true) {
                const skip = escapeLength(text, i);
                if (skip == 0) break;
                i += skip;
            }
            const c = at(text, i);
            if (c == 0 or isSpace(c)) {
                var new_line = false;
                if (w <= width or space == null) {
                    var start = bol;
                    if (c == 0 and i == start) return;
                    if (space) |sp| {
                        start = sp;
                    } else {
                        try out.appendNTimes(gpa, ' ', @intCast(@max(indent, 0)));
                    }
                    try out.appendSlice(gpa, text[start..i]);
                    if (c == 0) return;
                    space = i;
                    if (c == '\t') {
                        w |= 0x07;
                    } else if (c == '\n') {
                        space.? += 1;
                        const after = at(text, space.?);
                        if (after == '\n') {
                            try out.append(gpa, '\n');
                            new_line = true;
                        } else if (!std.ascii.isAlphanumeric(after)) {
                            new_line = true;
                        } else {
                            try out.append(gpa, ' ');
                        }
                    }
                    if (!new_line) {
                        w += 1;
                        i += 1;
                    }
                } else new_line = true;
                if (new_line) {
                    try out.append(gpa, '\n');
                    const sp = space.?;
                    i = sp + @intFromBool(isSpace(at(text, sp)));
                    bol = i;
                    space = null;
                    indent = indent2;
                    w = indent;
                }
                continue;
            }
            if (assume_utf8) {
                const decoded = unicodewidth.decode(text[i..]) orelse {
                    assume_utf8 = false;
                    out.shrinkRetainingCapacity(orig_len);
                    continue :retry;
                };
                w += unicodewidth.width(decoded.char);
                i += decoded.len;
            } else {
                w += 1;
                i += 1;
            }
        }
    }
}

/// `base` with what a repository's configuration decides filled in: the
/// comment string from `core.commentChar` (or `core.commentString`) and
/// whether `trailer.*` is configured. `auto` reads as `#`, which is what
/// git's trailer parser sees for a commit already made.
pub fn configured(config: *const config_mod.Config, base: Options) Options {
    var options = base;
    options.comment = "#";
    for ([_][]const u8{ "core.commentchar", "core.commentstring" }) |key| {
        if (config.get(key)) |raw| {
            if (raw.len != 0 and !std.mem.eql(u8, raw, "auto")) options.comment = raw;
        }
    }
    options.trailer_config = false;
    for (config.entries.items) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.section, "trailer")) options.trailer_config = true;
    }
    return options;
}

test "a subject folds where git's -w folds it" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try addWrappedText(gpa, &out, "a b c d e f g h i j k l m n o p q r s t u v w x y z", 2, 4, 12);
    try std.testing.expectEqualStrings("  a b c d e\n    f g h i\n    j k l m\n    n o p q\n    r s t u\n    v w x y\n    z", out.items);
}

const testgit = @import("../testing/git.zig");
const repo_mod = @import("../repo.zig");
const revwalk = @import("../revwalk.zig");

fn commitAs(r: *testgit.Repo, io: Io, author: []const u8, committer: []const u8, msg: []const u8) !void {
    const lt = std.mem.indexOfScalar(u8, committer, '<').?;
    const name = try std.fmt.allocPrint(r.gpa, "user.name={s}", .{std.mem.trim(u8, committer[0..lt], " ")});
    defer r.gpa.free(name);
    const email = try std.fmt.allocPrint(r.gpa, "user.email={s}", .{committer[lt + 1 .. committer.len - 1]});
    defer r.gpa.free(email);
    const who = try std.fmt.allocPrint(r.gpa, "--author={s}", .{author});
    defer r.gpa.free(who);
    try r.exec(io, &.{ "-c", name, "-c", email, "commit", "-q", "--allow-empty", "--allow-empty-message", "--cleanup=verbatim", who, "-m", msg });
}

fn shortlogOf(gpa: Allocator, io: Io, repo: *repo_mod.Repository, options: Options) ![]u8 {
    var s = try Shortlog.init(gpa, configured(repo.configuration(), options));
    defer s.deinit();
    var walk: revwalk.Walk = .init(gpa, &repo.odb);
    defer walk.deinit();
    const head = (try repo.head(io)).?;
    defer gpa.free(head.name);
    try walk.push(head.oid);
    while (try walk.next(io)) |c| try s.add(io, &repo.odb, c.oid);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try s.write(&out.writer);
    return out.toOwnedSlice();
}

test "shortlog groups, sorts, counts and folds as git shortlog does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    const ann = "Ann Lee <ann@x>";
    const bob = "bob <BOB@x>";
    const cy = "Cy Old <cy@old>";
    try commitAs(&r, io, ann, bob, "first commit");
    try commitAs(&r, io, bob, bob, "[PATCH 1/2] fix the thing\n\nbody\n");
    try commitAs(&r, io, cy, ann, "  leading spaces and\na subject over\ntwo lines\n\nCo-authored-by: Bob <bob@x>\nCo-authored-by: Dee <dee@x>\n");
    try commitAs(&r, io, ann, cy, "");
    try commitAs(&r, io, "Zed <z@x>", ann, "Reviewed-by: Ann Lee <ann@x>\n");
    try commitAs(&r, io, ann, ann, "中文字符 wide characters in a subject long enough to be folded by the wrapping options here");
    try commitAs(&r, io, bob, cy, "[PATCH] another\n\nReviewed-by: just text\nco-authored-by: Ann Lee <ann@x>\nCo-authored-by: Ann Lee <ann@x>\n");
    try commitAs(&r, io, cy, bob, "a subject that is long enough that the default width of seventy-six columns has to fold it somewhere");
    try r.writeFile(io, ".mailmap", "Cy New <cy@new> <cy@old>\nBob B <bob@x>\n");

    var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var mm = try mailmap_mod.Mailmap.load(gpa, io, &repo);
    defer mm.deinit();

    const Case = struct { args: []const []const u8, options: Options };
    const cases = [_]Case{
        .{ .args = &.{}, .options = .{} },
        .{ .args = &.{"-s"}, .options = .{ .summary = true } },
        .{ .args = &.{"-n"}, .options = .{ .numbered = true } },
        .{ .args = &.{"-sne"}, .options = .{ .summary = true, .numbered = true, .email = true } },
        .{ .args = &.{"-e"}, .options = .{ .email = true } },
        .{ .args = &.{"-c"}, .options = .{ .groups = &.{.committer} } },
        .{ .args = &.{ "--group=author", "--group=committer", "-s" }, .options = .{ .groups = &.{ .author, .committer }, .summary = true } },
        .{ .args = &.{"--group=trailer:co-authored-by"}, .options = .{ .groups = &.{.{ .trailer = "co-authored-by" }} } },
        .{ .args = &.{ "--group=trailer:reviewed-by", "--group=author", "-e" }, .options = .{ .groups = &.{ .{ .trailer = "reviewed-by" }, .author }, .email = true } },
        .{ .args = &.{"-w"}, .options = .{ .wrap = .{} } },
        .{ .args = &.{"-w20,2,4"}, .options = .{ .wrap = .{ .width = 20, .indent1 = 2, .indent2 = 4 } } },
        .{ .args = &.{"-w0,3,1"}, .options = .{ .wrap = .{ .width = 0, .indent1 = 3, .indent2 = 1 } } },
    };
    for (cases) |case| {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.append(gpa, "shortlog");
        try args.appendSlice(gpa, case.args);
        try args.append(gpa, "HEAD");
        const expected = try r.run(io, args.items);
        defer gpa.free(expected);
        var options = case.options;
        options.mailmap = &mm;
        const got = try shortlogOf(gpa, io, &repo, options);
        defer gpa.free(got);
        std.testing.expectEqualStrings(expected, got) catch |err| {
            std.debug.print("git shortlog {any} differs\n", .{case.args});
            return err;
        };
    }
}

test "shortlog refuses what it does not do by name" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.FormatGroupUnsupported, Shortlog.init(gpa, .{ .groups = &.{.{ .format = "%an" }} }));
    try std.testing.expectError(error.InvalidWrap, Shortlog.init(gpa, .{ .wrap = .{ .width = 6 } }));
    try std.testing.expectError(error.TrailerConfigUnsupported, Shortlog.init(gpa, .{ .groups = &.{.{ .trailer = "a" }}, .trailer_config = true }));
}
