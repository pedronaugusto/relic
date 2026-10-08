//! Integer overflow: a count or a length an attacker sizes -- lines in a
//! blob, bytes in a path or a patch, a padding width, an attributes line --
//! that wraps the integer holding it, and with it a buffer's bounds, which
//! a release build no longer checks. Each fix has its owner: the line
//! numbering in parallax's line diff, reached through `diff.zig` and
//! `merge/blobmerge.zig`; path building in the object walk (`walk/`);
//! `pretty.zig`'s placeholders; `worktree/attributes.zig` (`patterns/`);
//! and `patch/apply.zig`.

const std = @import("std");
const Io = std.Io;

const diff = @import("../../diff/diff.zig");
const blobmerge = @import("../../merge/blobmerge.zig");
const objectwalk = @import("../../walk/objectwalk.zig");
const pretty = @import("../../pretty/pretty.zig");
const archive = @import("../../archive.zig");
const attributes = @import("../../patterns/attributes.zig");
const apply = @import("../../patch/apply.zig");
const repo_mod = @import("../../repo/repo.zig");
const hash = @import("../../hash/hash.zig");
const hostile = @import("hostile.zig");
const testgit = @import("../git.zig");

/// A slice of `n` items that is never read: what a size check is asked
/// about before it looks at a byte.
fn unread(comptime T: type, n: usize) []const T {
    const many: [*]const T = @ptrFromInt(@alignOf(T)); // safe: a size check refuses it before any item is read
    return many[0..n];
}

test "git 2.3.10 (MAX_XDIFF_SIZE, no t/ test): a text too large for the line diff is refused before a byte of it is read" {
    if (comptime @sizeOf(usize) < 8) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // A line is numbered with a `u32`, so a side of 4 GiB is refused.
    const huge = unread(u8, @as(usize, std.math.maxInt(u32)) + 1);
    try std.testing.expectError(error.InputTooLarge, diff.unifiedBody(gpa, &out.writer, huge, "", .{}));
    try std.testing.expectError(error.InputTooLarge, diff.unifiedBody(gpa, &out.writer, "", huge, .{}));
    // A merge takes a side larger than MAX_XDIFF_SIZE as binary, as git's
    // `ll_merge` does.
    try std.testing.expectError(error.BinaryBlob, blobmerge.blobs(gpa, "a", unread(u8, blobmerge.max_text_size + 1), "", .{}));
    // And an ordinary diff is unchanged by the checks.
    try diff.unifiedBody(gpa, &out.writer, "a\nb\n", "a\nc\n", .{});
    try std.testing.expect(out.written().len != 0);
}

test "CVE-2016-2324 (with CVE-2016-2315, no t/ test): an object walk names every blob of a deep tree of long names whole" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var h = try hostile.Harness.init(gpa, io);
    defer h.deinit(io);
    const depth = 200;
    const name = &@as([250]u8, @splat('n'));
    var tree = try h.writeTree(gpa, io, &.{.{ .mode = "100644", .name = name, .oid = try h.blob(io, "leaf\n") }});
    for (1..depth) |_| tree = try h.writeTree(gpa, io, &.{.{ .mode = "40000", .name = name, .oid = tree }});
    var collected = try objectwalk.missing(gpa, io, &h.db, &.{tree}, .{ .exclude = &.{} });
    defer collected.deinit();
    var longest: usize = 0;
    for (collected.entries) |entry| longest = @max(longest, entry.hint.len);
    try std.testing.expectEqual(@as(usize, depth * name.len + depth - 1), longest);
}

test "CVE-2022-41903, t4205-log-pretty-formats 'log --pretty with overflowing wrapping directive' and '...padding directive': the widths are refused by name, in a format and in export-subst" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, ".gitattributes", "f export-subst\n");
    try git.writeFile(io, "f", "$Format:%<(2147483649)%x30$\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    const head = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    const commit = try hash.Oid.parse(.sha1, head);
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_][]const u8{
        "%w(2147483649,1,1)%x30",
        "%w(1,2147483649,1)%x30",
        "%w(1,1,2147483649)%x30",
        "%<(2147483649)%x30",
        "%>(2147483646)%x41%41%>(2147483646)%x41",
        "%B%<(1)%x30",
    }) |format| {
        var out: std.ArrayList(u8) = .empty;
        try std.testing.expectError(error.UnsupportedPlaceholder, pretty.formatCommit(arena.allocator(), io, .{ .db = repo.objectDatabase(), .oid = commit, .format = format }, &out, .{}));
    }
    var sink: Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try std.testing.expectError(error.UnsupportedPlaceholder, archive.archive(gpa, io, .{ .repo = &repo, .treeish = commit }, &sink.writer, .{}));
}

test "CVE-2022-23521, t0003-attributes 'large attributes line ignored in tree' and '...ignores trailing content': a line of 2048 bytes or more is passed over whole" {
    const gpa = std.testing.allocator;
    var attrs = try attributes.Attrs.init(gpa, false);
    defer attrs.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    // git's two vectors: 2048 bytes naming `path`, and 2048 bytes before
    // `trailing attribute`, which an older git broke into a second line.
    try text.print(gpa, "path {d:0>2043}\n", .{1});
    try text.print(gpa, "a {d:0>2045}trailing attribute\n", .{1});
    // One byte shorter is a line like any other.
    try text.print(gpa, "kept {d:0>2042}\n", .{1});
    try attrs.addText(text.items, "", ".gitattributes", 1);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try attrs.lookup(arena.allocator(), "path", false)).items.len);
    try std.testing.expectEqual(@as(usize, 0), (try attrs.lookup(arena.allocator(), "trailing", false)).items.len);
    try std.testing.expectEqual(@as(usize, 0), (try attrs.lookup(arena.allocator(), "a", false)).items.len);
    try std.testing.expectEqual(@as(usize, 1), (try attrs.lookup(arena.allocator(), "kept", false)).items.len);
}

test "git 2.39.0 apply input cap, t4141-apply-too-large 'git apply rejects patches that are too large': a patch of 1023 MiB or more is refused before it is read" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const huge = unread(u8, apply.max_patch_size);
    try std.testing.expectError(error.PatchTooLarge, apply.apply(gpa, io, &repo, huge, .{}));
    try std.testing.expectError(error.PatchTooLarge, apply.keptFiles(gpa, huge, .{}));
}
