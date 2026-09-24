//! A shallow repository's boundary: `.git/shallow`.
//!
//! A clone made with `--depth` holds only the newest part of its history.
//! The commits at the cut are listed in `shallow`, one name to a line and
//! sorted, and every walk treats them as having no parents — their parents
//! are not in the repository and nothing may look for them. The file is in
//! the common directory, replaced through `shallow.lock` as git replaces
//! it, and removed when the last cut goes: a repository with no `shallow`
//! file is whole.
//!
//! What a fetch says about the cut comes from the server: `shallow <oid>`
//! for a commit that is now at the boundary, `unshallow <oid>` for one
//! whose parents have arrived. `apply` makes the new list from the old one
//! and those.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const fs = @import("fs.zig");

const Oid = hash.Oid;

/// The file's name in the common directory.
pub const file_name = "shallow";

/// Errors from reading the file.
pub const ReadError = error{
    /// A line that is not an object name of the repository's hash.
    MalformedShallowFile,
} || Allocator.Error || Io.Dir.ReadFileAllocError;

/// Errors from reading or writing the file.
pub const Error = ReadError || fs.LockError || fs.CommitError || Io.Dir.DeleteFileError;

/// The commits at the boundary, or an empty set for a whole repository.
/// The set is the caller's.
pub fn read(gpa: Allocator, io: Io, common_dir: Io.Dir, kind: hash.Kind) ReadError!Oid.Set {
    var set: Oid.Set = .empty;
    errdefer set.deinit(gpa);
    const text = common_dir.readFileAlloc(io, file_name, gpa, .limited(1 << 30)) catch |err| switch (err) {
        error.FileNotFound => return set,
        else => |e| return e,
    };
    defer gpa.free(text);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const oid = Oid.parse(kind, line) catch return error.MalformedShallowFile;
        try set.put(gpa, oid, {});
    }
    return set;
}

/// Replace the file with `set`, sorted as git sorts it, or remove it when
/// `set` is empty.
pub fn write(gpa: Allocator, io: Io, common_dir: Io.Dir, set: *const Oid.Set) Error!void {
    if (set.count() == 0) {
        common_dir.deleteFile(io, file_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        return;
    }
    const sorted = try gpa.alloc(Oid, set.count());
    defer gpa.free(sorted);
    var it = set.keyIterator();
    var i: usize = 0;
    while (it.next()) |oid| : (i += 1) sorted[i] = oid.*;
    std.mem.sort(Oid, sorted, {}, struct {
        fn lessThan(_: void, a: Oid, b: Oid) bool {
            return a.order(b) == .lt;
        }
    }.lessThan);
    var buffer: [4096]u8 = undefined;
    var lock = try fs.LockFile.open(gpa, io, common_dir, file_name, &buffer, .{});
    defer lock.deinit(io);
    const w = lock.writer();
    for (sorted) |oid| try w.print("{f}\n", .{oid});
    try lock.commit(io);
}

/// The boundary after a fetch: `current`, with every commit in `added`
/// and without every one in `removed`.
pub fn apply(gpa: Allocator, current: *const Oid.Set, added: []const Oid, removed: []const Oid) Allocator.Error!Oid.Set {
    var next = try current.clone(gpa);
    errdefer next.deinit(gpa);
    for (added) |oid| try next.put(gpa, oid, {});
    for (removed) |oid| _ = next.remove(oid);
    return next;
}

test "the file is written sorted, read back, and removed when the boundary goes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = try Oid.parse(.sha1, "b" ** 40);
    const b = try Oid.parse(.sha1, "a" ** 40);
    var empty: Oid.Set = .empty;
    var set = try apply(gpa, &empty, &.{ a, b }, &.{});
    defer set.deinit(gpa);
    try write(gpa, io, tmp.dir, &set);
    const text = try tmp.dir.readFileAlloc(io, file_name, gpa, .unlimited);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("a" ** 40 ++ "\n" ++ "b" ** 40 ++ "\n", text);
    var back = try read(gpa, io, tmp.dir, .sha1);
    defer back.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), back.count());

    var none = try apply(gpa, &back, &.{}, &.{ a, b });
    defer none.deinit(gpa);
    try write(gpa, io, tmp.dir, &none);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, file_name, .{}));
    var whole = try read(gpa, io, tmp.dir, .sha1);
    defer whole.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), whole.count());
}
