//! `git shortlog`: commits grouped by who made them, as git groups, sorts
//! and prints them.
//!
//! A shortlog is fed commits in the order a walk gives them -- `rev_walk.Walk`
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
//! `--group=format:<format>` groups by what `pretty` makes of the format,
//! Trailers are read as the repository's `trailer.*` settings say. A
//! commit in another encoding is converted as git converts it, and what is
//! written is in `format_context.output_encoding`, which `configured` sets
//! to the log's.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const ctype = @import("../text.zig").ctype;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const message = @import("../object/message.zig");
const trailer = @import("../object/trailer.zig");
const mailmap_mod = @import("../rev_walk/mailmap.zig");
const config_mod = @import("../config/config.zig");
const pretty = @import("pretty.zig");
const mailfmt = @import("../mail/format.zig");

const Oid = hash.Oid;

/// What a commit is grouped by: `--group`.
pub const Group = union(enum) {
    /// `--group=author`, the default.
    author,
    /// `--group=committer`, `-c`.
    committer,
    /// `--group=trailer:<key>`; the key is matched without case.
    trailer: []const u8,
    /// `--group=format:<format>`, or a group given with a `%`: what the
    /// format makes of each commit, through `pretty`.
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
    /// How trailers are read: the repository's `trailer.*` settings and
    /// `core.commentChar`, which decides where a message's trailer block
    /// ends. Borrowed.
    trailers: trailer.Settings = .{},
    /// What a format group's placeholders need besides the commit.
    format_context: pretty.Context = .{},
};

/// Errors from a shortlog.
pub const Error = error{
    /// A `-w` whose width is no wider than an indent: git's usage error.
    InvalidWrap,
} || pretty.Error;

const Record = struct {
    count: usize = 0,
    subjects: std.ArrayList([]const u8) = .empty,
};

/// The order `write` lists records in: by count first under `-n`, then
/// by name.
const RecordOrder = struct {
    keys: []const []const u8,
    values: []const Record,
    numbered: bool,

    fn lessThan(ctx: RecordOrder, a: usize, b: usize) bool {
        if (ctx.numbered and ctx.values[a].count != ctx.values[b].count)
            return ctx.values[a].count > ctx.values[b].count;
        return std.mem.order(u8, ctx.keys[a], ctx.keys[b]) == .lt;
    }
};

/// Commits being grouped.
pub const Shortlog = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    options: Options,
    trailer_keys: []const []const u8,
    /// The format groups' formats, in the order given.
    formats: []const []const u8,
    author: bool,
    committer: bool,
    dedup: bool,
    records: std.array_hash_map.String(Record) = .empty,

    /// A shortlog with nothing in it yet.
    pub fn init(gpa: Allocator, options: Options) Self.Error!Shortlog {
        var author = false;
        var committer = false;
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(gpa);
        var formats: std.ArrayList([]const u8) = .empty;
        defer formats.deinit(gpa);
        for (options.groups) |group| switch (group) {
            .author => author = true,
            .committer => committer = true,
            .trailer => |key| try keys.append(gpa, key),
            .format => |format| try formats.append(gpa, format),
        };
        if (options.groups.len == 0) author = true;
        if (options.wrap) |w| {
            if (w.width != 0 and ((w.indent1 != 0 and w.width <= w.indent1) or (w.indent2 != 0 and w.width <= w.indent2)))
                return error.InvalidWrap;
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const owned_keys = try arena.allocator().dupe([]const u8, keys.items);
        const owned_formats = try arena.allocator().dupe([]const u8, formats.items);
        const kinds = @as(usize, @intFromBool(author)) + @intFromBool(committer) +
            @intFromBool(owned_keys.len != 0) + @intFromBool(owned_formats.len != 0);
        // git keeps the author's and committer's groups as formats after
        // the ones given.
        const format_count = owned_formats.len + @intFromBool(author) + @intFromBool(committer);
        return .{
            .gpa = gpa,
            .arena = arena,
            .options = options,
            .trailer_keys = owned_keys,
            .formats = owned_formats,
            .author = author,
            .committer = committer,
            // `shortlog_needs_dedup`: more than one kind of group, more
            // than one format, or any trailer.
            .dedup = kinds > 1 or format_count > 1 or owned_keys.len != 0,
        };
    }

    /// Release everything.
    pub fn deinit(s: *Shortlog) void {
        for (s.records.values()) |*r| r.subjects.deinit(s.gpa);
        s.records.deinit(s.gpa);
        s.arena.deinit();
        s.* = undefined;
    }

    /// Read the commit `oid` from `db` and add it: git's
    /// `shortlog_add_commit`.
    pub fn add(s: *Shortlog, io: Io, db: *odb_mod.Odb, oid: Oid) Self.Error!void {
        const found = try db.read(io, oid);
        defer db.allocator().free(found.bytes);
        if (found.type != .commit) return error.UnexpectedObjectType;
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        // git formats each piece in UTF-8, the commit converted first, and
        // writes it in the log's output encoding
        const ctx = s.options.format_context;
        const utf8 = try pretty.reencodeCommit(a, found.bytes, "UTF-8");
        var commit = try object.Commit.parse(a, db.objectFormat(), utf8.bytes);
        defer commit.deinit();
        const output = pretty.outputEncoding(ctx.output_encoding, utf8.encoding);
        const oneline: []const u8 = if (s.options.summary) "" else blk: {
            const subject = try pretty.toOutput(a, try message.onelineSubject(a, commit.message), output);
            break :blk if (subject.len == 0) "<none>" else subject;
        };

        var seen: std.StringHashMapUnmanaged(void) = .empty;
        if (s.trailer_keys.len != 0) {
            // git reads trailers from the commit buffer at its first blank
            // line, the blank line itself included, so the title paragraph
            // can be a trailer block of its own.
            var shown = try object.Commit.parse(a, db.objectFormat(), (try pretty.reencodeCommit(a, found.bytes, ctx.output_encoding)).bytes);
            defer shown.deinit();
            const body = try std.mem.concat(a, u8, &.{ "\n\n", shown.message });
            for (try trailer.iterate(a, s.options.trailers, body)) |t| {
                if (!s.wantsKey(t.key)) continue;
                const value = try s.identOf(a, t.value) orelse t.value;
                if ((try seen.getOrPut(a, value)).found_existing) continue;
                try s.insert(value, oneline);
            }
        }
        // `insert_records_from_format`, the formats given first.
        for (s.formats) |format| {
            var text: std.ArrayList(u8) = .empty;
            try pretty.formatCommit(a, io, .{ .db = db, .oid = oid, .format = format }, &text, ctx);
            if (s.dedup and (try seen.getOrPut(a, text.items)).found_existing) continue;
            try s.insert(text.items, oneline);
        }
        if (s.author) try s.insertPerson(a, &seen, commit.author, output, oneline);
        if (s.committer) try s.insertPerson(a, &seen, commit.committer, output, oneline);
    }

    fn wantsKey(s: *const Shortlog, key: []const u8) bool {
        for (s.trailer_keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return true;
        return false;
    }

    fn insertPerson(s: *Shortlog, a: Allocator, seen: *std.StringHashMapUnmanaged(void), who: object.Signature, output: ?[]const u8, oneline: []const u8) ErrorNamespace.Error!void {
        const text = try pretty.toOutput(a, try s.formatPerson(a, trimName(who.name), who.email), output);
        if (s.dedup and (try seen.getOrPut(a, text)).found_existing) return;
        try s.insert(text, oneline);
    }

    /// `%aN` or `%aN <%aE>`.
    fn formatPerson(s: *const Shortlog, a: Allocator, name: []const u8, email: []const u8) Allocator.Error![]const u8 {
        const shown = if (s.options.mailmap) |m| m.map(name, email) else mailmap_mod.Identity{ .name = name, .email = email };
        if (s.options.email) return a.print("{s} <{s}>", .{ shown.name, shown.email });
        return a.dupe(u8, shown.name);
    }

    /// `parse_ident`: a trailer value that reads as `Name <email>` is shown
    /// as a person is, and anything else as it is written.
    fn identOf(s: *const Shortlog, a: Allocator, value: []const u8) Allocator.Error!?[]const u8 {
        const lt = std.mem.findScalar(u8, value, '<') orelse return null;
        const gt = std.mem.findScalarPos(u8, value, lt + 1, '>') orelse return null;
        const person = try s.formatPerson(a, trimName(value[0..lt]), value[lt + 1 .. gt]);
        return person;
    }

    /// `insert_one_record`.
    fn insert(s: *Shortlog, ident: []const u8, oneline_in: []const u8) ErrorNamespace.Error!void {
        const slot = try s.records.getOrPut(s.gpa, ident);
        if (!slot.found_existing) {
            slot.key_ptr.* = try s.arena.allocator().dupe(u8, ident);
            slot.value_ptr.* = .{};
        }
        const record = slot.value_ptr;
        record.count += 1;
        if (s.options.summary) return;

        var oneline = oneline_in;
        while (oneline.len > 0 and ctype.isSpace(oneline[0])) oneline = oneline[1..];
        const eol = std.mem.findScalar(u8, oneline, '\n') orelse oneline.len;
        if (std.mem.startsWith(u8, oneline, "[PATCH")) {
            if (std.mem.findScalar(u8, oneline, ']')) |eob| {
                if (eob < eol) oneline = oneline[eob + 1 ..];
            }
        }
        while (oneline.len > 0 and ctype.isSpace(oneline[0]) and oneline[0] != '\n') oneline = oneline[1..];
        const subject = try message.onelineSubject(s.arena.allocator(), oneline);
        try record.subjects.append(s.gpa, subject);
    }

    /// Errors from `write`.
    pub const WriteError = Io.Writer.Error || Allocator.Error;

    /// `shortlog_output`.
    pub fn write(s: *Shortlog, w: *Io.Writer) WriteError!void {
        const order = try s.gpa.alloc(usize, s.records.count());
        defer s.gpa.free(order);
        for (order, 0..) |*o, i| o.* = i;
        std.sort.pdq(usize, order, RecordOrder{ .keys = s.records.keys(), .values = s.records.values(), .numbered = s.options.numbered }, RecordOrder.lessThan);

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
                    try mailfmt.appendWrapped(s.gpa, &wrapped, msg, @intCast(opt.indent1), @intCast(opt.indent2), @intCast(opt.width));
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

/// `split_ident_line`'s name: up to the `<`, without whitespace after it.
fn trimName(name: []const u8) []const u8 {
    var end = name.len;
    while (end > 0 and ctype.isSpace(name[end - 1])) end -= 1;
    return name[0..end];
}

/// `base` with what a repository's configuration decides filled in: how
/// trailers are read, by the comment string and the `trailer.*` settings
/// (`auto` reads as `#`, which is what git's trailer parser sees for a
/// commit already made), and the encoding written,
/// `i18n.logOutputEncoding`. What it reads is `arena`'s.
pub fn configured(arena: Allocator, config: *const config_mod.Config, base: Options) (Allocator.Error || error{ InvalidCommentString, InvalidEncodingSetting })!Options {
    var options = base;
    options.trailers = try message.trailerSettings(arena, config);
    options.format_context.output_encoding = try message.logOutputEncoding(config);
    return options;
}

test "a subject folds where git's -w folds it" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try mailfmt.appendWrapped(gpa, &out, "a b c d e f g h i j k l m n o p q r s t u v w x y z", 2, 4, 12);
    try std.testing.expectEqualStrings("  a b c d e\n    f g h i\n    j k l m\n    n o p q\n    r s t u\n    v w x y\n    z", out.items);
}

const testgit = @import("../testing/git.zig");
const repo_mod = @import("../repo/repo.zig");
const rev_walk = @import("../walk/walk.zig");

fn commitAs(io: Io, r: *testgit.Repo, author: []const u8, committer: []const u8, msg: []const u8) !void {
    const lt = std.mem.findScalar(u8, committer, '<').?;
    const name = try r.gpa.print("user.name={s}", .{std.mem.trim(u8, committer[0..lt], " ")});
    defer r.gpa.free(name);
    const email = try r.gpa.print("user.email={s}", .{committer[lt + 1 .. committer.len - 1]});
    defer r.gpa.free(email);
    const who = try r.gpa.print("--author={s}", .{author});
    defer r.gpa.free(who);
    try r.exec(io, &.{ "-c", name, "-c", email, "commit", "-q", "--allow-empty", "--allow-empty-message", "--cleanup=verbatim", who, "-m", msg });
}

fn shortlogOf(gpa: Allocator, io: Io, repo: *repo_mod.Repository, options: Options) ![]u8 {
    var settings_arena: std.heap.ArenaAllocator = .init(gpa);
    defer settings_arena.deinit();
    var s = try Shortlog.init(gpa, try configured(settings_arena.allocator(), repo.configuration(), options));
    defer s.deinit();
    var walk: rev_walk.Walk = .init(gpa, repo.objectDatabase());
    defer walk.deinit();
    const head = (try repo.head(io)).?;
    defer gpa.free(head.name);
    try walk.push(head.oid);
    while (try walk.next(io)) |c| try s.add(io, repo.objectDatabase(), c.oid);
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
    try commitAs(io, &r, ann, bob, "first commit");
    try commitAs(io, &r, bob, bob, "[PATCH 1/2] fix the thing\n\nbody\n");
    try commitAs(io, &r, cy, ann, "  leading spaces and\na subject over\ntwo lines\n\nCo-authored-by: Bob <bob@x>\nCo-authored-by: Dee <dee@x>\n");
    try commitAs(io, &r, ann, cy, "");
    try commitAs(io, &r, "Zed <z@x>", ann, "Reviewed-by: Ann Lee <ann@x>\n");
    try commitAs(io, &r, ann, ann, "中文字符 wide characters in a subject long enough to be folded by the wrapping options here");
    try commitAs(io, &r, bob, cy, "[PATCH] another\n\nReviewed-by: just text\nco-authored-by: Ann Lee <ann@x>\nCo-authored-by: Ann Lee <ann@x>\n");
    try commitAs(io, &r, cy, bob, "a subject that is long enough that the default width of seventy-six columns has to fold it somewhere");
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
        .{ .args = &.{"--group=format:%cn <%ce>"}, .options = .{ .groups = &.{.{ .format = "%cn <%ce>" }} } },
        .{ .args = &.{ "--group=%ae", "-n" }, .options = .{ .groups = &.{.{ .format = "%ae" }}, .numbered = true } },
        .{ .args = &.{ "--group=author", "--group=format:%an", "-s" }, .options = .{ .groups = &.{ .author, .{ .format = "%an" } }, .summary = true } },
        .{ .args = &.{ "--group=format:%ad", "--group=format:%cs", "--group=trailer:co-authored-by", "-s" }, .options = .{ .groups = &.{ .{ .format = "%ad" }, .{ .format = "%cs" }, .{ .trailer = "co-authored-by" } }, .summary = true } },
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
    try std.testing.expectError(error.InvalidWrap, Shortlog.init(gpa, .{ .wrap = .{ .width = 6 } }));
}
