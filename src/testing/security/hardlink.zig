//! Hard links: a local clone that links its object files to the source's,
//! so that the source's owner -- another user on the same disk -- can
//! rewrite the clone's objects later. relic's local transport
//! (`transport/local.zig`) reads the source's objects and writes one pack
//! of its own: no file of a clone is ever a file of its source.

const std = @import("std");
const Io = std.Io;

const clone_mod = @import("../../transport/clone.zig");
const object = @import("../../object.zig");
const testgit = @import("../git.zig");

/// The inode of every file under `dir`.
fn inodes(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, into: *std.AutoHashMapUnmanaged(Io.File.INode, void)) !usize {
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = try dir.statFile(io, entry.path, .{ .follow_symlinks = false });
        try into.put(gpa, stat.inode, {});
        count += 1;
    }
    return count;
}

test "CVE-2024-32020, t5605-clone-local: a local clone shares no object file with its source" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try source.writeFile(io, "a", "one\n");
    try source.exec(io, &.{ "add", "a" });
    try source.exec(io, &.{ "commit", "-q", "-m", "one" });
    try source.exec(io, &.{ "repack", "-q", "-a", "-d" });
    try source.writeFile(io, "b", "two\n");
    try source.exec(io, &.{ "add", "b" });
    try source.exec(io, &.{ "commit", "-q", "-m", "two" });
    const path = try source.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);

    var owner = try testgit.Repo.init(gpa, io, &.{});
    defer owner.deinit();
    try owner.dir.createDirPath(io, "c");
    var target = try owner.dir.openDir(io, "c", .{ .iterate = true });
    defer target.close(io);
    const who: object.Signature = .{ .name = "S", .email = "s@example.com", .when_secs = 1, .offset_minutes = 0 };
    var clone = try clone_mod.clone(gpa, io, path, target, .{ .who = who });
    clone.deinit(io);

    var theirs: std.AutoHashMapUnmanaged(Io.File.INode, void) = .empty;
    defer theirs.deinit(gpa);
    var source_objects = try source.dir.openDir(io, ".git/objects", .{ .iterate = true });
    defer source_objects.close(io);
    try std.testing.expect(try inodes(gpa, io, source_objects, &theirs) != 0);
    var ours: std.AutoHashMapUnmanaged(Io.File.INode, void) = .empty;
    defer ours.deinit(gpa);
    var clone_objects = try target.openDir(io, ".git/objects", .{ .iterate = true });
    defer clone_objects.close(io);
    try std.testing.expect(try inodes(gpa, io, clone_objects, &ours) != 0);
    var it = ours.keyIterator();
    while (it.next()) |inode| try std.testing.expect(!theirs.contains(inode.*));
}
