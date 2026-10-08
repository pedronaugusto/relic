//! `working-tree-encoding` against the real git: twin repositories, git
//! staging and checking out one and relic the other, with the blobs and
//! the files on the disk compared.

const std = @import("std");
const Io = std.Io;

const testgit = @import("git.zig");
const ft = @import("../checkout/filter_test.zig");
const encoding = @import("../text/encoding.zig");

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
