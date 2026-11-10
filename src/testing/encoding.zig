//! Encodings against the real git. `working-tree-encoding`: twin
//! repositories, git staging and checking out one and relic the other, with
//! the blobs and the files on the disk compared. Commits in Latin-1 and
//! UTF-8: what `git log`, `git shortlog` and `git format-patch` write of
//! them in each `i18n.logOutputEncoding`, and the commits a cherry-pick and
//! `git commit-tree` make under `i18n.commitEncoding`. Each single-byte
//! encoding of the standard's that relic converts, byte by byte and
//! character by character, as `git log` converts it.

const std = @import("std");
const Io = std.Io;

const testgit = @import("git.zig");
const history = @import("history.zig");
const repo_mod = @import("../repo/repo.zig");
const hash = @import("../hash/hash.zig");
const pretty = @import("../pretty/pretty.zig");
const shortlog = @import("../pretty/shortlog.zig");
const formatpatch = @import("../patch/format.zig");
const sequencer = @import("../commit/sequencer.zig");
const object = @import("../object/object.zig");
const message = @import("../object/message.zig");
const ft = @import("filters.zig");
const encoding = @import("../text.zig").encoding;
const legacy = @import("../text/legacy.zig");
const legacy_tables = @import("../text/legacy/tables.zig");

const testing = std.testing;

const attributes =
    \\*.u16 text working-tree-encoding=UTF-16
    \\*.u16le working-tree-encoding=UTF-16LE
    \\*.u16be working-tree-encoding=UTF-16BE
    \\*.u16lebom working-tree-encoding=UTF-16LE-BOM
    \\*.u32 working-tree-encoding=UTF-32
    \\*.u32le working-tree-encoding=UTF-32LE
    \\*.crlf16 text eol=crlf working-tree-encoding=UTF-16LE
    \\*.u8 working-tree-encoding=UTF-8
    \\
;

/// Text in UTF-8, with a character outside the basic plane.
const text = "caf\xc3\xa9 \xf0\x9f\x98\x80\nline two\n";

/// `text` in `e`, as the file in the working tree that git takes in.
fn encoded(gpa: std.mem.Allocator, e: encoding.Encoding, bom: enum { order, little, big }) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const which: encoding.Encoding = switch (bom) {
        .order => e,
        .little => .utf16le_bom,
        .big => .utf16be_bom,
    };
    return gpa.dupe(u8, try encoding.fromUtf8(arena.allocator(), which, text));
}

test "UTF-16 and UTF-32 files are stored as UTF-8 and checked out as git checks them out" {
    const gpa = testing.allocator;
    const io = testing.io;
    const le_bom = try encoded(gpa, .utf16, .little);
    defer gpa.free(le_bom);
    const be_bom = try encoded(gpa, .utf16, .big);
    defer gpa.free(be_bom);
    const le = try encoded(gpa, .utf16le, .order);
    defer gpa.free(le);
    const be = try encoded(gpa, .utf16be, .order);
    defer gpa.free(be);
    const le32 = try encoded(gpa, .utf32le, .order);
    defer gpa.free(le32);
    const crlf = try encoded(gpa, .utf16le, .order);
    defer gpa.free(crlf);
    // UTF-32 with a mark, written as the platform's git reads it either way.
    var u32_bytes: std.ArrayList(u8) = .empty;
    defer u32_bytes.deinit(gpa);
    try u32_bytes.appendSlice(gpa, "\xff\xfe\x00\x00");
    try u32_bytes.appendSlice(gpa, le32);

    const files = [_][2][]const u8{
        .{ ".gitattributes", attributes },
        .{ "little.u16", le_bom },
        .{ "big.u16", be_bom },
        .{ "a.u16le", le },
        .{ "a.u16be", be },
        .{ "a.u16lebom", le_bom },
        .{ "a.u32", u32_bytes.items },
        .{ "a.u32le", le32 },
        .{ "a.crlf16", crlf },
        .{ "a.u8", text },
        .{ "empty.u16", "" },
    };
    var twin = try ft.Twin.init(gpa, io, &.{}, &files);
    defer twin.deinit();

    try twin.theirs.exec(io, &.{ "add", "-A" });
    const theirs_tree = try ft.treeOf(gpa, io, &twin.theirs);
    const ours_tree = try ft.relicAdd(gpa, io, twin.ours.dir, .{});
    if (!ours_tree.eql(theirs_tree)) {
        const listing = try twin.theirs.run(io, &.{ "ls-files", "-s" });
        defer gpa.free(listing);
        const ours = try twin.ours.run(io, &.{ "ls-files", "-s" });
        defer gpa.free(ours);
        std.debug.print("relic's tree is not git's\ngit:\n{s}relic:\n{s}", .{ listing, ours });
        return error.TestUnexpectedResult;
    }
    // What is stored is UTF-8.
    const stored = try twin.theirs.run(io, &.{ "cat-file", "blob", ":a.u16le" });
    defer gpa.free(stored);
    try testing.expectEqualStrings(text, stored);

    // git finds relic's index clean against the files.
    const status = try twin.ours.run(io, &.{ "diff", "--name-only" });
    defer gpa.free(status);
    try testing.expectEqualStrings("", status);

    try ft.emptyWorktree(io, twin.theirs.dir);
    try twin.theirs.exec(io, &.{ "checkout", "--", "." });
    try ft.emptyWorktree(io, twin.ours.dir);
    _ = try ft.relicCheckout(gpa, io, twin.ours.dir, ours_tree, .{});
    for (files) |file| try ft.expectSameFile(gpa, io, &twin.ours, &twin.theirs, file[0]);
}

test "a file that breaks git's byte order mark rules is refused when it is stored, as git refuses it" {
    const gpa = testing.allocator;
    const io = testing.io;
    const le = try encoded(gpa, .utf16le, .order);
    defer gpa.free(le);
    const le_bom = try encoded(gpa, .utf16, .little);
    defer gpa.free(le_bom);
    const cases = [_][2][]const u8{
        // UTF-16 needs a mark, and UTF-16LE may not have one.
        .{ "missing.u16", le },
        .{ "extra.u16le", le_bom },
        // Not UTF-16 at all: an odd number of bytes.
        .{ "odd.u16le", "abc" },
    };
    for (cases) |case| {
        var twin = try ft.Twin.init(gpa, io, &.{}, &.{ .{ ".gitattributes", attributes }, case });
        defer twin.deinit();
        twin.theirs.report_failures = false;
        try testing.expectError(error.GitFailed, twin.theirs.run(io, &.{ "add", "-A" }));
        testing.expectError(error.WorkingTreeEncodingFailed, ft.relicAdd(gpa, io, twin.ours.dir, .{})) catch |err| {
            std.debug.print("{s} was stored\n", .{case[0]});
            return err;
        };
    }
}

test "an encoding other than UTF-8, UTF-16 and UTF-32 is refused by name, and true or false is no encoding" {
    const gpa = testing.allocator;
    const io = testing.io;
    const cases = [_]struct { attrs: []const u8, err: anyerror }{
        .{ .attrs = "*.txt working-tree-encoding=SHIFT-JIS\n", .err = error.UnsupportedAttribute },
        .{ .attrs = "*.txt working-tree-encoding\n", .err = error.InvalidWorkingTreeEncoding },
        .{ .attrs = "*.txt -working-tree-encoding\n", .err = error.InvalidWorkingTreeEncoding },
    };
    for (cases) |case| {
        var twin = try ft.Twin.init(gpa, io, &.{}, &.{ .{ ".gitattributes", case.attrs }, .{ "a.txt", "plain\n" } });
        defer twin.deinit();
        try testing.expectError(case.err, ft.relicAdd(gpa, io, twin.ours.dir, .{}));
    }
    // git dies over true and false too.
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try r.writeFile(io, ".gitattributes", "*.txt working-tree-encoding\n");
    try r.writeFile(io, "a.txt", "plain\n");
    r.report_failures = false;
    try testing.expectError(error.GitFailed, r.run(io, &.{ "add", "-A" }));
}

/// Write `bytes` as an object of `kind` and return its name.
fn hashObject(gpa: std.mem.Allocator, io: Io, r: *testgit.Repo, kind: []const u8, bytes: []const u8) ![]u8 {
    const out = try r.runInput(io, &.{ "hash-object", "-t", kind, "-w", "--stdin" }, bytes);
    defer r.gpa.free(out);
    return gpa.dupe(u8, std.mem.trimEnd(u8, out, "\n"));
}

/// The commits these compare, made as bytes so each says exactly what it
/// says: `main` at an empty root, `topic` on it with a commit in Latin-1
/// (its author's name too), one in UTF-8 holding a character Latin-1 does
/// not have, one naming Latin-1 by another spelling, and one naming UTF-8.
/// Each adds a file, so each picks cleanly.
fn encodedHistory(io: Io, r: *testgit.Repo) !void {
    const gpa = r.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const empty = try hashObject(a, io, r, "tree", "");
    const people = "author Fixture <fixture@example.com> 1700000000 +0000\ncommitter Fixture <fixture@example.com> 1700000000 +0000\n";
    var parent = try hashObject(a, io, r, "commit", try a.print("tree {s}\n{s}\nbase\n", .{ empty, people }));
    try r.exec(io, &.{ "update-ref", "refs/heads/main", parent });
    try r.exec(io, &.{ "reset", "-q", "--hard" });
    const commits = [_]struct { file: []const u8, header: []const u8 }{
        .{ .file = "a.txt", .header = "author Ren\xe9 Lat <rene@example.com> 1700000100 +0100\ncommitter Fixture <fixture@example.com> 1700000100 +0000\nencoding ISO-8859-1\n\ncaf\xe9 subject\n\nA body \xe9t\xe9 in Latin-1.\n" },
        .{ .file = "b.txt", .header = "author Fixture <fixture@example.com> 1700000200 +0000\ncommitter Fixture <fixture@example.com> 1700000200 +0000\n\neuro \xe2\x82\xac sign\n\nNot in Latin-1.\n" },
        .{ .file = "c.txt", .header = "author Fixture <fixture@example.com> 1700000300 +0000\ncommitter Fixture <fixture@example.com> 1700000300 +0000\nencoding latin1\n\nna\xefve spelling\n" },
        .{ .file = "d.txt", .header = "author J\xc3\xb6rg <jorg@example.com> 1700000400 +0000\ncommitter Fixture <fixture@example.com> 1700000400 +0000\nencoding UTF-8\n\nsaid UTF-8: caf\xc3\xa9\n" },
    };
    var entries: std.ArrayList(u8) = .empty;
    for (commits) |c| {
        const blob = try hashObject(a, io, r, "blob", c.file);
        try entries.print(a, "100644 blob {s}\t{s}\n", .{ blob, c.file });
        const tree_out = try r.runInput(io, &.{"mktree"}, entries.items);
        const tree = std.mem.trimEnd(u8, tree_out, "\n");
        parent = try hashObject(a, io, r, "commit", try a.print("tree {s}\nparent {s}\n{s}", .{ tree, parent, c.header }));
        gpa.free(tree_out);
    }
    try r.exec(io, &.{ "update-ref", "refs/heads/topic", parent });
}

/// The encodings `i18n.logOutputEncoding` is compared in: unset, UTF-8 in
/// two spellings, and Latin-1 in two.
const log_encodings = [_]?[]const u8{ null, "UTF-8", "utf8", "ISO-8859-1", "latin1" };

fn setLogEncoding(io: Io, r: *testgit.Repo, e: ?[]const u8) !void {
    if (e) |name| try r.exec(io, &.{ "config", "i18n.logOutputEncoding", name }) else {
        r.report_failures = false;
        defer r.report_failures = true;
        // unsetting what is not set exits 5; either way it is unset
        r.exec(io, &.{ "config", "--unset", "i18n.logOutputEncoding" }) catch |err| switch (err) {
            error.GitFailed => {},
            else => |e2| return e2,
        };
    }
}

test "commits in Latin-1 and UTF-8 are written as git log, git shortlog and git format-patch write them in each log encoding" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try encodedHistory(io, &r);
    const listing = try r.run(io, &.{ "rev-list", "main..topic" });
    defer gpa.free(listing);
    const formats = [_][]const u8{ "%s|%an|%ae|%e", "%B", "%b%n%aN %cn" };
    const main_text = try r.line(io, &.{ "rev-parse", "main" });
    defer gpa.free(main_text);
    const main_oid = try hash.Oid.parse(.sha1, main_text);
    const topic_text = try r.line(io, &.{ "rev-parse", "topic" });
    defer gpa.free(topic_text);
    const topic = try hash.Oid.parse(.sha1, topic_text);
    for (log_encodings) |e| {
        try setLogEncoding(io, &r, e);
        var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
        defer repo.deinit(io);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // git log --format, one commit at a time
        var lines = std.mem.tokenizeScalar(u8, listing, '\n');
        while (lines.next()) |hex| {
            for (formats) |format| {
                const theirs = try r.run(io, &.{ "log", "-1", try a.print("--format={s}", .{format}), hex });
                defer gpa.free(theirs);
                var ours: std.ArrayList(u8) = .empty;
                try pretty.formatCommit(a, io, .{ .db = repo.objectDatabase(), .oid = try hash.Oid.parse(.sha1, hex), .format = format }, &ours, .{ .output_encoding = try message.logOutputEncoding(repo.configuration()) });
                try ours.append(a, '\n');
                testing.expectEqualStrings(theirs, ours.items) catch |err| {
                    std.debug.print("git log --format={s} {s} in {?s}\n", .{ format, hex, e });
                    return err;
                };
            }
        }
        // git shortlog, with and without emails
        for ([_]bool{ false, true }) |email| {
            const theirs = try r.run(io, &.{ "shortlog", if (email) "-e" else "-n", "main..topic" });
            defer gpa.free(theirs);
            var s = try shortlog.Shortlog.init(gpa, try shortlog.configured(a, repo.configuration(), .{ .email = email, .numbered = !email }));
            defer s.deinit();
            lines = std.mem.tokenizeScalar(u8, listing, '\n');
            while (lines.next()) |hex| try s.add(io, repo.objectDatabase(), try hash.Oid.parse(.sha1, hex));
            var w: Io.Writer.Allocating = .init(a);
            try s.write(&w.writer);
            testing.expectEqualStrings(theirs, w.written()) catch |err| {
                std.debug.print("git shortlog in {?s}\n", .{e});
                return err;
            };
        }
        // git format-patch, with a cover letter
        if (try testgit.gitAtLeast(gpa, io, 2, 43)) {
            const theirs = try r.run(io, &.{ "format-patch", "--stdout", "--no-signature", "--cover-letter", "main..topic" });
            defer gpa.free(theirs);
            const sender: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };
            var series = try formatpatch.format(gpa, io, &repo, .{ .upstream = main_oid, .tip = topic }, .{ .cover_letter = .on, .cover = .{ .sender = sender } });
            defer series.deinit();
            var w: Io.Writer.Allocating = .init(a);
            try series.writeMbox(&w.writer);
            testing.expectEqualStrings(theirs, w.written()) catch |err| {
                std.debug.print("git format-patch in {?s}\n", .{e});
                return err;
            };
        }
    }
}

/// A commit of `body` under `header_encoding` (none when null) on an empty tree.
fn commitOf(a: std.mem.Allocator, io: Io, r: *testgit.Repo, header_encoding: ?[]const u8, body: []const u8) ![]u8 {
    const empty = try hashObject(a, io, r, "tree", "");
    const people = "author Fixture <fixture@example.com> 1700000000 +0000\ncommitter Fixture <fixture@example.com> 1700000000 +0000\n";
    const header = if (header_encoding) |e| try a.print("encoding {s}\n", .{e}) else "";
    return hashObject(a, io, r, "commit", try a.print("tree {s}\n{s}{s}\n{s}", .{ empty, people, header, body }));
}

/// `git log -1 --format=%B` of `hex` in `out_encoding` (UTF-8 when null), and relic's.
fn expectLoggedAlike(a: std.mem.Allocator, io: Io, r: *testgit.Repo, hex: []const u8, out_encoding: ?[]const u8, what: []const u8) !void {
    try setLogEncoding(io, r, out_encoding);
    const theirs = try r.run(io, &.{ "log", "-1", "--format=%B", hex });
    defer r.gpa.free(theirs);
    var repo = try repo_mod.Repository.open(r.gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var ours: std.ArrayList(u8) = .empty;
    try pretty.formatCommit(a, io, .{ .db = repo.objectDatabase(), .oid = try hash.Oid.parse(.sha1, hex), .format = "%B" }, &ours, .{ .output_encoding = try message.logOutputEncoding(repo.configuration()) });
    try ours.append(a, '\n');
    testing.expectEqualStrings(theirs, ours.items) catch |err| {
        std.debug.print("{s} in {?s}\n", .{ what, out_encoding });
        return err;
    };
}

test "each encoding is converted as git log converts it: every sequence both iconvs read, every character both write, and a byte or character neither has kept as it was" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var seen: std.AutoHashMapUnmanaged(*const legacy.Legacy, void) = .empty;
    for (legacy_tables.names) |entry| {
        const name, const l = entry;
        if ((try seen.getOrPut(a, l)).found_existing) continue;
        // Every sequence past ASCII relic reads, and the ASCII it reads
        // otherwise, each after a space so that none composes with the one
        // before, in a commit that names the encoding, read out in UTF-8.
        var bytes: Writing = .{};
        var chars: Writing = .{};
        var b: [4]u8 = undefined;
        for (0x21..0x100) |b0| {
            b[0] = @intCast(b0);
            const alone = try readOne(a, l, b[0..1], &bytes, &chars);
            // two bytes: a lead and its trail, or a letter and the mark it
            // composes with
            if (alone and l.longest == 1) continue;
            for (0x21..0x100) |b1| {
                b[1] = @intCast(b1);
                if (try readOne(a, l, b[0..2], &bytes, &chars) or alone) continue;
                for (0xa1..0xff) |b2| {
                    if (l.encoding != .euc_jp) break;
                    b[2] = @intCast(b2);
                    _ = try readOne(a, l, b[0..3], &bytes, &chars);
                }
                // GB18030's four bytes, one in 61 of them
                for (0x81..0xff) |b2| for (0x30..0x3a) |b3| {
                    if (l.encoding != .gb18030 or b1 > 0x39) break;
                    if ((b0 * 7 + b1 * 3 + b2 * 5 + b3) % 61 != 0) continue;
                    b[2] = @intCast(b2);
                    b[3] = @intCast(b3);
                    _ = try readOne(a, l, b[0..4], &bytes, &chars);
                };
            }
        }
        const subject = try a.print("every sequence of {s}\n\n", .{name});
        try expectLoggedAlike(a, io, &r, try commitOf(a, io, &r, name, try a.print("{s}{s}\n", .{ subject, bytes.list.items })), null, name);
        // Every character relic writes, one in 31 past the Basic
        // Multilingual Plane, in a UTF-8 commit read out in the encoding.
        var written: Writing = .{};
        var cp: u21 = 0x21;
        while (cp <= 0x10ffff) : (cp += 1) {
            if (cp >= 0xd800 and cp <= 0xdfff) continue;
            if (cp > 0xffff and cp % 31 != 0) continue;
            var i: usize = 0;
            var out: [4]u8 = undefined;
            _ = legacy.encodeAt(l, &.{cp}, &i, &out) orelse continue;
            var utf8: [4]u8 = undefined;
            try written.add(a, utf8[0..try std.unicode.utf8Encode(cp, &utf8)]);
        }
        try expectLoggedAlike(a, io, &r, try commitOf(a, io, &r, null, try a.print("{s}{s}\n", .{ subject, written.list.items })), name, name);
        // A byte no sequence begins with, and a character none of these
        // writes that Apple's iconv has no transliteration for (U+1F600;
        // U+4E00 it writes as "gal." in ISO-8859-2): git keeps the message
        // as it was. Not a byte Apple's iconv reads and glibc's does not,
        // which relic refuses and the Mac's git converts: windows-874's
        // 0xFF, and every byte glibc's KOI-8 lacks, which Apple's reads as
        // KOI8-R's.
        var refused: ?u8 = null;
        if (!std.mem.eql(u8, name, "koi8")) for ([_]u8{ 0xff, 0x81, 0xa0, 0x80 }) |byte| {
            if (byte == 0xff and std.mem.eql(u8, name, "windows-874")) continue;
            var i: usize = 0;
            var cps: [2]u21 = undefined;
            if (legacy.decodeAt(l, &.{ byte, 0x20 }, &i, &cps) == null) {
                refused = byte;
                break;
            }
        };
        if (refused) |byte| try expectLoggedAlike(a, io, &r, try commitOf(a, io, &r, name, try a.print("refused {x:0>2}: {c}\n", .{ byte, byte })), null, name);
        try expectLoggedAlike(a, io, &r, try commitOf(a, io, &r, null, "unmappable \xf0\x9f\x98\x80\n"), name, name);
    }
}

/// Text built a piece at a time, each after a space, sixteen to a line.
const Writing = struct {
    list: std.ArrayList(u8) = .empty,
    count: usize = 0,

    fn add(w: *Writing, a: std.mem.Allocator, piece: []const u8) !void {
        try w.list.append(a, if (w.count % 16 == 15) '\n' else ' ');
        try w.list.appendSlice(a, piece);
        w.count += 1;
    }
};

/// Whether relic reads `seq` as one sequence; if so it and its characters
/// are added.
fn readOne(a: std.mem.Allocator, l: *const legacy.Legacy, seq: []const u8, bytes: *Writing, chars: *Writing) !bool {
    var i: usize = 0;
    var cps: [2]u21 = undefined;
    const n = legacy.decodeAt(l, seq, &i, &cps) orelse return false;
    if (i != seq.len) return false;
    // ASCII read as itself is the commit's own text.
    if (seq.len == 1 and seq[0] < 0x80 and n == 1 and cps[0] == seq[0]) return true;
    var utf8: [8]u8 = undefined;
    var len: usize = 0;
    for (cps[0..n]) |cp| len += try std.unicode.utf8Encode(cp, utf8[len..]);
    try bytes.add(a, seq);
    try chars.add(a, utf8[0..len]);
    return true;
}

test "a picked commit and a new one are in i18n.commitEncoding, as git's are" {
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_]?[]const u8{ null, "ISO-8859-1" }) |e| {
        var pair: history.Pair = undefined;
        try history.Pair.init(gpa, io, &pair, .files, encodedHistory);
        defer pair.deinit();
        if (e) |name| for ([_]*testgit.Repo{ &pair.git, &pair.ours }) |r| try r.exec(io, &.{ "config", "i18n.commitEncoding", name });
        try pair.git.exec(io, &.{ "cherry-pick", "main..topic" });
        {
            var repo = try pair.open(io);
            defer repo.deinit(io);
            const listing = try pair.ours.run(io, &.{ "rev-list", "--reverse", "main..topic" });
            defer gpa.free(listing);
            var commits: std.ArrayList(hash.Oid) = .empty;
            defer commits.deinit(gpa);
            var lines = std.mem.tokenizeScalar(u8, listing, '\n');
            while (lines.next()) |hex| try commits.append(gpa, try hash.Oid.parse(.sha1, hex));
            var outcome = try sequencer.pick(gpa, io, &repo, commits.items, .{ .who = history.who });
            defer outcome.deinit();
        }
        const theirs = try pair.git.run(io, &.{ "log", "--format=%H%n%B", "main" });
        defer gpa.free(theirs);
        const ours = try pair.ours.run(io, &.{ "log", "--format=%H%n%B", "main" });
        defer gpa.free(ours);
        testing.expectEqualStrings(theirs, ours) catch |err| {
            std.debug.print("cherry-pick under i18n.commitEncoding={?s}\n", .{e});
            return err;
        };

        // a commit written new: git commit-tree, the message from stdin
        const text_in = "new caf\xe9\n";
        const theirs_new = try pair.git.runInput(io, &.{ "commit-tree", "4b825dc642cb6eb9a060e54bf8d69288fbee4904" }, text_in);
        defer gpa.free(theirs_new);
        var repo = try pair.open(io);
        defer repo.deinit(io);
        const made = try repo.writeCommit(io, .{ .tree = try hash.Oid.parse(.sha1, "4b825dc642cb6eb9a060e54bf8d69288fbee4904"), .author = history.who, .committer = history.who, .message = text_in }, .{});
        var hex: [hash.max_hex_len]u8 = undefined;
        testing.expectEqualStrings(std.mem.trimEnd(u8, theirs_new, "\n"), made.hex(&hex)) catch |err| {
            const git_bytes = try pair.git.run(io, &.{ "cat-file", "commit", std.mem.trimEnd(u8, theirs_new, "\n") });
            defer gpa.free(git_bytes);
            const our_bytes = try pair.ours.run(io, &.{ "cat-file", "commit", made.hex(&hex) });
            defer gpa.free(our_bytes);
            std.debug.print("commit-tree under i18n.commitEncoding={?s}\ngit:\n{s}relic:\n{s}", .{ e, git_bytes, our_bytes });
            return err;
        };
    }
}

test "core.checkRoundtripEncoding converts a stored file back and refuses one that is not the same, as git's check_roundtrip does" {
    const gpa = testing.allocator;
    const io = testing.io;
    const le_bom = try encoded(gpa, .utf16, .little);
    defer gpa.free(le_bom);
    const be_bom = try encoded(gpa, .utf16, .big);
    defer gpa.free(be_bom);
    const le = try encoded(gpa, .utf16le, .order);
    defer gpa.free(le);
    const Case = struct { list: ?[]const u8, file: [2][]const u8 };
    const cases = [_]Case{
        .{ .list = null, .file = .{ "little.u16", le_bom } },
        .{ .list = "UTF-16", .file = .{ "little.u16", le_bom } },
        .{ .list = "UTF-16", .file = .{ "big.u16", be_bom } },
        .{ .list = "utf-32, utf-16", .file = .{ "little.u16", le_bom } },
        .{ .list = "UTF-32,UTF-16", .file = .{ "big.u16", be_bom } },
        // only the first occurrence counts, and this one is UTF-16LE's
        .{ .list = "UTF-16LE UTF-16", .file = .{ "little.u16", le_bom } },
        .{ .list = "UTF-16LE", .file = .{ "a.u16le", le } },
        .{ .list = "UTF-16", .file = .{ "a.u16le", le } },
    };
    for (cases) |case| {
        var twin = try ft.Twin.init(gpa, io, &.{}, &.{ .{ ".gitattributes", attributes }, case.file });
        defer twin.deinit();
        if (case.list) |list| {
            try twin.theirs.exec(io, &.{ "config", "core.checkRoundtripEncoding", list });
            try twin.ours.exec(io, &.{ "config", "core.checkRoundtripEncoding", list });
        }
        twin.theirs.report_failures = false;
        const theirs_ok = if (twin.theirs.run(io, &.{ "add", "-A" })) |out| blk: {
            gpa.free(out);
            break :blk true;
        } else |err| switch (err) {
            error.GitFailed => false,
            else => |e| return e,
        };
        const ours_tree: ?hash.Oid = ft.relicAdd(gpa, io, twin.ours.dir, .{}) catch |err| switch (err) {
            error.WorkingTreeEncodingRoundtrip => null,
            else => |e| return e,
        };
        testing.expectEqual(theirs_ok, ours_tree != null) catch |err| {
            std.debug.print("{?s} with {s}: git {s} it\n", .{ case.list, case.file[0], if (theirs_ok) "stored" else "refused" });
            return err;
        };
        if (ours_tree) |tree| try testing.expect(tree.eql(try ft.treeOf(gpa, io, &twin.theirs)));
    }
}

test "attr.tree's attributes write a checkout in place of the checked-out tree's own, as git's do" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try ft.Twin.init(gpa, io, &.{}, &.{ .{ ".gitattributes", "*.txt -text\n" }, .{ "a.txt", "a\nb\n" } });
    defer twin.deinit();
    for ([_]*testgit.Repo{ &twin.theirs, &twin.ours }) |repo| {
        try repo.exec(io, &.{ "add", "-A" });
        try repo.exec(io, &.{ "commit", "-qm", "plain" });
        try repo.exec(io, &.{ "tag", "plain" });
        try repo.writeFile(io, ".gitattributes", "*.txt text eol=crlf\n");
        // a directory `attr.tree` has no attributes file in
        try repo.writeFile(io, "sub/.gitattributes", "*.txt text eol=crlf\n");
        try repo.writeFile(io, "sub/c.txt", "c\nd\n");
        try repo.exec(io, &.{ "add", "-A" });
        try repo.exec(io, &.{ "commit", "-qm", "crlf" });
        try repo.exec(io, &.{ "config", "attr.tree", "plain" });
    }
    const tree = try ft.treeOf(gpa, io, &twin.ours);
    try ft.emptyWorktree(io, twin.theirs.dir);
    try twin.theirs.exec(io, &.{ "checkout", "--", "." });
    try ft.emptyWorktree(io, twin.ours.dir);
    _ = try ft.relicCheckout(gpa, io, twin.ours.dir, tree, .{});
    try ft.expectSameFile(gpa, io, &twin.ours, &twin.theirs, "a.txt");
    try ft.expectSameFile(gpa, io, &twin.ours, &twin.theirs, "sub/c.txt");
    const written = try twin.theirs.dir.readFileAlloc(io, "a.txt", gpa, .unlimited);
    defer gpa.free(written);
    // `attr.tree`'s `-text`, not the tree's `eol=crlf`
    try testing.expectEqualStrings("a\nb\n", written);
}
