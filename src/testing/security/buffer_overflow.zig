//! Buffer overflows: a path name longer than the fixed array holding it.
//! git moved its path buffers to `strbuf` in 2.2.3; relic's are slices,
//! bounds-checked in a safe build, and the few fixed arrays left fall back
//! or refuse by name when a name does not fit. A release build checks no
//! bounds, so what is proved here is that no name reaches past an array:
//! each operation a hostile tree of long names meets runs in this safe
//! build without a trap. The fixed arrays are in `worktree.zig` (the
//! architecture's `checkout/`), `object.zig` and `index.zig`.

const std = @import("std");
const Io = std.Io;

const object = @import("../../object/object.zig");
const archive = @import("../../archive.zig");
const repo_mod = @import("../../repo/repo.zig");
const hash = @import("../../hash/hash.zig");
const hostile = @import("hostile.zig");
const testgit = @import("../git.zig");

const long = &@as([5000]u8, @splat('x'));

/// `git mktree` of `entries`, `<mode> <type> <oid>\t<name>` each.
fn mktree(gpa: std.mem.Allocator, io: Io, git: *testgit.Repo, entries: []const u8) !hash.Oid {
    const out = try git.runInput(io, &.{"mktree"}, entries);
    defer gpa.free(out);
    return hash.Oid.parse(.sha1, std.mem.trimEnd(u8, out, "\n"));
}

test "git 2.2.3 (strbuf for path buffers, no t/ test): a tree of names longer than any buffer is sorted as git sorts it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const blob_text = try git.runInput(io, &.{ "hash-object", "-w", "--stdin" }, "leaf\n");
    defer gpa.free(blob_text);
    const blob = try hash.Oid.parse(.sha1, std.mem.trimEnd(u8, blob_text, "\n"));
    var hex: [hash.max_hex_len]u8 = undefined;
    const inner_text = try gpa.print("100644 blob {s}\tleaf\n", .{blob.hex(&hex)});
    defer gpa.free(inner_text);
    const inner = try mktree(gpa, io, &git, inner_text);

    // A tree named `long` and a blob named `long-a`: git puts the blob
    // first, `-` sorting before the `/` a tree's name is compared with.
    var hex2: [hash.max_hex_len]u8 = undefined;
    const listing = try gpa.print("040000 tree {s}\t{s}\n100644 blob {s}\t{s}-a\n", .{ inner.hex(&hex2), long, blob.hex(&hex), long });
    defer gpa.free(listing);
    const theirs = try mktree(gpa, io, &git, listing);

    var builder: object.Tree.Builder = .init(gpa, .sha1);
    defer builder.deinit();
    try builder.add(.tree, long, inner);
    try builder.add(.file, long ++ "-a", blob);
    const bytes = try builder.build();
    defer gpa.free(bytes);
    try std.testing.expect(hash.Hasher.object(.sha1, "tree", bytes).eql(theirs));
}

test "git 2.2.3 (strbuf for path buffers, no t/ test): a path longer than PATH_MAX is checked out, archived and refused only by name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var h = try hostile.Harness.init(gpa, io);
    defer h.deinit(io);
    const name = &@as([250]u8, @splat('d'));
    var tree = try h.writeTree(gpa, io, &.{.{ .mode = "100644", .name = name, .oid = try h.blob(io, "leaf\n") }});
    // Twenty levels: a path of five thousand bytes, past every fixed
    // array and past what most systems open in one call.
    for (0..20) |_| tree = try h.writeTree(gpa, io, &.{.{ .mode = "40000", .name = name, .oid = tree }});
    const wide = try h.writeTree(gpa, io, &.{
        .{ .mode = "40000", .name = "deep", .oid = tree },
        .{ .mode = "100644", .name = long, .oid = try h.blob(io, "long\n") },
    });
    // Written, or refused with a name: either is an answer, a trap is not.
    if (h.checkout(gpa, io, wide)) |_| {} else |_| {}

    // The archive git writes of the same commit, byte for byte.
    var hex: [hash.max_hex_len]u8 = undefined;
    const commit_text = try h.repo.runInput(io, &.{ "commit-tree", tree.hex(&hex) }, "deep\n");
    defer gpa.free(commit_text);
    const commit = try hash.Oid.parse(.sha1, std.mem.trimEnd(u8, commit_text, "\n"));
    const theirs = try h.repo.run(io, &.{ "archive", "--format=tar", commit.hex(&hex) });
    defer gpa.free(theirs);
    var repo = try repo_mod.Repository.open(gpa, io, h.repo.dir, .{});
    defer repo.deinit(io);
    var ours: Io.Writer.Allocating = .init(gpa);
    defer ours.deinit();
    try archive.archive(gpa, io, &repo, commit, .{}, &ours.writer);
    try std.testing.expectEqualSlices(u8, theirs, ours.written());
}
