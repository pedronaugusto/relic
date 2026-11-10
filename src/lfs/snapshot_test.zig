//! A worktree snapshot with relic's own LFS supplied as its native provider:
//! what the filters write goes to the snapshot's private store.

const std = @import("std");
const testing = std.testing;
const core = @import("relic_core");
const snapshot = core.worktree.snapshot;
const repo = core.repo;
const filter_mod = @import("filter.zig");
const lfs = @import("lfs.zig");
const testgit = @import("../testing/git.zig");

test "snapshot keeps native LFS writes inside the private store" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    const source_path = try source.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(source_path);
    const external = try std.Io.Dir.path.join(gpa, &.{ source_path, "external-lfs" });
    defer gpa.free(external);
    try source.exec(io, &.{ "config", "lfs.storage", external });
    try source.writeFile(io, ".gitattributes", "*.bin filter=lfs\n");
    try source.writeFile(io, "large.bin", "the LFS content\n");
    var r = try repo.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer r.deinit(io);
    var private = testing.tmpDir(.{ .iterate = true });
    defer private.cleanup();
    var store = try snapshot.Store.open(gpa, io, private.dir, .{});
    defer store.deinit(io);
    const captured = try store.capture(io, .{ .repository = &r }, .{ .native_provider = filter_mod.provider(&.{}) });
    try testing.expectError(error.FileNotFound, source.dir.access(io, "external-lfs", .{}));
    var dest = testing.tmpDir(.{ .iterate = true });
    defer dest.cleanup();
    _ = try store.restore(io, captured.snapshot, dest.dir, .{});
    const pointer_text = try dest.dir.readFileAlloc(io, "large.bin", gpa, .limited(1024));
    defer gpa.free(pointer_text);
    const pointer = try lfs.Pointer.decode(pointer_text);
    const payloads: lfs.Store = .{ .base = store.dir.borrow().*, .root = "lfs" };
    try testing.expect(try payloads.contains(io, &pointer));
}
