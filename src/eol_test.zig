//! Line endings against the real git: the attributes and settings that
//! decide them, in twin repositories, git staging and checking out one and
//! relic the other.

const std = @import("std");
const Io = std.Io;

const testgit = @import("testgit.zig");
const ft = @import("filter_test.zig");

const testing = std.testing;

/// The fixture settings without `core.autocrlf`, so the repository's own
/// configuration decides it for git as it does for relic.
const settings_without_autocrlf = blk: {
    const all = testgit.default_settings;
    var out: [all.len - 2][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < all.len) : (i += 2) {
        if (std.mem.eql(u8, all[i + 1], "core.autocrlf=false")) continue;
        out[n] = all[i];
        out[n + 1] = all[i + 1];
        n += 2;
    }
    break :blk out;
};

/// Stage `files` in both, compare the trees, then empty both working trees,
/// check out, and compare every file.
fn expectSameAsGit(gpa: std.mem.Allocator, io: Io, autocrlf: []const u8, files: []const [2][]const u8) !void {
    var twin = try ft.Twin.init(gpa, io, &.{.{ "core.autocrlf", autocrlf }}, files);
    defer twin.deinit();
    twin.ours.defaults = &settings_without_autocrlf;
    twin.theirs.defaults = &settings_without_autocrlf;

    try twin.theirs.exec(io, &.{ "add", "-A" });
    const theirs_tree = try ft.treeOf(gpa, io, &twin.theirs);
    const ours_tree = try ft.relicAdd(gpa, io, twin.ours.dir, .{});
    if (!ours_tree.eql(theirs_tree)) {
        const listing = try twin.theirs.run(io, &.{ "ls-files", "--eol" });
        defer gpa.free(listing);
        std.debug.print("core.autocrlf={s}: relic's tree is not git's\n{s}", .{ autocrlf, listing });
        return error.TestUnexpectedResult;
    }

    try ft.emptyWorktree(io, twin.theirs.dir);
    try twin.theirs.exec(io, &.{ "checkout", "--", "." });
    try ft.emptyWorktree(io, twin.ours.dir);
    _ = try ft.relicCheckout(gpa, io, twin.ours.dir, ours_tree, .{});
    for (files) |file| try ft.expectSameFile(gpa, io, &twin.ours, &twin.theirs, file[0]);
}

test "the crlf attribute and every text value are read as git reads them" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_][2][]const u8{
        .{
            ".gitattributes",
            \\*.a crlf
            \\*.b -crlf
            \\*.c crlf=input
            \\*.d text=bogus
            \\*.k text=bogus crlf
            \\*.i crlf=input eol=crlf
            \\*.t text
            \\*.u text=input
            \\*.e eol=lf
            \\*.n !text crlf
            \\
        },
        .{ "f.a", "x\r\ny\r\nz\n" },
        .{ "f.b", "x\r\ny\r\n" },
        .{ "f.c", "x\r\ny\r\n" },
        .{ "f.d", "x\r\ny\r\n" },
        .{ "f.k", "x\r\ny\r\n" },
        .{ "f.i", "x\r\ny\n" },
        .{ "f.t", "x\r\ny\n" },
        .{ "f.u", "x\r\ny\n" },
        .{ "f.e", "x\r\ny\n" },
        .{ "f.n", "x\r\ny\n" },
        .{ "plain", "x\r\ny\n" },
    };
    for ([_][]const u8{ "false", "true", "input" }) |autocrlf| {
        try expectSameAsGit(gpa, io, autocrlf, &files);
    }
}

test "a file whose indexed version has CRLF endings keeps them where the content decides, as in git" {
    const gpa = testing.allocator;
    const io = testing.io;
    const cases = [_][2][]const u8{
        .{ "false", "* text=auto\n" },
        .{ "false", "* text=auto eol=crlf\n" },
        .{ "true", "" },
        .{ "input", "" },
        // `text` is not the content deciding, and normalises regardless.
        .{ "false", "* text\n" },
    };
    for (cases) |case| {
        var twin = try ft.Twin.init(gpa, io, &.{.{ "core.autocrlf", case[0] }}, &.{
            .{ "kept.txt", "one\r\ntwo\r\n" },
            .{ "touched.txt", "same\r\n" },
        });
        defer twin.deinit();
        twin.ours.defaults = &settings_without_autocrlf;
        twin.theirs.defaults = &settings_without_autocrlf;
        for ([_]*testgit.Repo{ &twin.ours, &twin.theirs }) |r| {
            // Committed with its carriage returns, before any rule said
            // otherwise.
            try r.exec(io, &.{ "-c", "core.autocrlf=false", "add", "-A" });
            try r.exec(io, &.{ "commit", "-q", "-m", "crlf" });
            if (case[1].len > 0) try r.writeFile(io, ".gitattributes", case[1]);
            try r.writeFile(io, "kept.txt", "one\r\ntwo\r\nthree\r\n");
            try r.dir.deleteFile(io, "touched.txt");
            try r.writeFile(io, "touched.txt", "same\r\n");
            try r.writeFile(io, "new.txt", "x\r\ny\r\n");
        }

        // Status first: a file rewritten with the same bytes is unmodified
        // only if it is not normalised against the index.
        var result = try ft.relicStatus(gpa, io, twin.ours.dir, .{});
        defer result.deinit();
        const porcelain = try twin.ours.run(io, &.{ "status", "--porcelain", "--untracked-files=no" });
        defer gpa.free(porcelain);
        const git_says_touched = std.mem.indexOf(u8, porcelain, "touched.txt") != null;
        try testing.expectEqual(git_says_touched, result.find("touched.txt") != null);

        try twin.theirs.exec(io, &.{ "add", "-A" });
        const ours_tree = try ft.relicAdd(gpa, io, twin.ours.dir, .{});
        if (!ours_tree.eql(try ft.treeOf(gpa, io, &twin.theirs))) {
            std.debug.print("core.autocrlf={s} attributes {s}: relic's tree is not git's\n", .{ case[0], case[1] });
            return error.TestUnexpectedResult;
        }
    }
}
