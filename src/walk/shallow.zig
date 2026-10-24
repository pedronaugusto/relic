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

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const fs = @import("../fs/fs.zig");

const Oid = hash.Oid;

/// The file's name in the common directory.
pub const file_name = "shallow";

/// Errors from reading the file.
pub const ReadError = error{
    /// A line that is not an object name of the repository's hash.
    MalformedShallowFile,
} || Allocator.Error || Io.Dir.ReadFileAllocError;

/// Errors from reading or writing the file.
pub const Error = error{
    /// The file changed since it was read: another writer's boundary would
    /// be lost.
    ShallowChanged,
} || ReadError || fs.LockFile.OpenError || fs.CommitError || fs.StatError || Io.Dir.DeleteFileError;

/// The commits at the boundary, or an empty set for a whole repository.
/// The set is the caller's.
pub fn read(gpa: Allocator, io: Io, common_dir: Io.Dir, kind: hash.Kind) Self.ReadError!Oid.Set {
    var set: Oid.Set = .empty;
    errdefer set.deinit(gpa);
    const text = fs.readWhole(common_dir, io, file_name, gpa, .limited(1 << 30)) catch |err| switch (err) {
        error.FileNotFound => return set,
        else => |e| return e,
    };
    defer gpa.free(text);
    // git's `is_repository_shallow`: each line begins with an object name,
    // whatever follows it on the line, and a line that does not, an empty
    // one among them, is "bad shallow line".
    var at: usize = 0;
    while (at < text.len) {
        const end = std.mem.findScalarPos(u8, text, at, '\n') orelse text.len;
        const line = text[at..end];
        at = end + 1;
        if (line.len < kind.hexLen()) return error.MalformedShallowFile;
        const oid = Oid.parse(kind, line[0..kind.hexLen()]) catch return error.MalformedShallowFile;
        try set.put(gpa, oid, {});
    }
    return set;
}

/// What the file was when it was read: its stat, or `null` when there was
/// none. A write refuses to replace a file that changed since.
pub const Seen = ?fs.Stat;

/// What `common_dir`'s shallow file is now.
pub fn seen(io: Io, common_dir: Io.Dir) fs.StatError!Seen {
    return fs.validityAt(io, common_dir, file_name);
}

/// How `write` takes its lock.
pub const WriteOptions = struct {
    /// The file as it was read; another writer's change since is
    /// `error.ShallowChanged`, as git's `check_shallow_file_for_update`
    /// dies on it.
    seen: Seen,
    /// What `core.sharedRepository` asks of the file's permissions.
    shared: fs.Shared = .umask,
    /// `core.lockfilePid`: the lock names its holder.
    pid_file: bool = false,
};

/// Replace the file with `set`, sorted as git sorts it, or remove it when
/// `set` is empty, under `shallow.lock`. What the file is afterwards comes
/// back, for the next write to check against.
pub fn write(gpa: Allocator, io: Io, common_dir: Io.Dir, set: *const Oid.Set, options: WriteOptions) Self.Error!Seen {
    var buffer: [4096]u8 = undefined;
    var lock = try fs.LockFile.open(gpa, io, common_dir, .{ .sub_path = file_name, .buffer = &buffer }, .{ .sync = .none, .shared = options.shared, .write_pid = options.pid_file });
    defer lock.deinit(io);
    if (!same(try seen(io, common_dir), options.seen)) return error.ShallowChanged;
    if (set.count() == 0) {
        common_dir.deleteFile(io, file_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        return null;
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
    const w = &lock;
    for (sorted) |oid| try w.print("{f}\n", .{oid});
    try lock.commit(io);
    return seen(io, common_dir);
}

fn same(a: Seen, b: Seen) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return x.mtime_sec == y.mtime_sec and x.mtime_nsec == y.mtime_nsec and x.ctime_sec == y.ctime_sec and
        x.ctime_nsec == y.ctime_nsec and x.ino == y.ino and x.dev == y.dev and x.size == y.size;
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
    const a = try Oid.parse(.sha1, &@as([40]u8, @splat('b')));
    const b = try Oid.parse(.sha1, &@as([40]u8, @splat('a')));
    var empty: Oid.Set = .empty;
    var set = try apply(gpa, &empty, &.{ a, b }, &.{});
    defer set.deinit(gpa);
    const written = try write(gpa, io, tmp.dir, &set, .{ .seen = null });
    const text = try fs.readWhole(tmp.dir, io, file_name, gpa, .unlimited);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(@as([40]u8, @splat('a')) ++ "\n" ++ @as([40]u8, @splat('b')) ++ "\n", text);
    var back = try read(gpa, io, tmp.dir, .sha1);
    defer back.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), back.count());

    var none = try apply(gpa, &back, &.{}, &.{ a, b });
    defer none.deinit(gpa);
    // A file another writer changed since it was read is not replaced.
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = @as([40]u8, @splat('c')) ++ "\n" ++ @as([40]u8, @splat('d')) ++ "\n\n" });
    try std.testing.expectError(error.ShallowChanged, write(gpa, io, tmp.dir, &none, .{ .seen = written }));
    try std.testing.expectError(error.ShallowChanged, write(gpa, io, tmp.dir, &none, .{ .seen = null }));
    _ = try write(gpa, io, tmp.dir, &none, .{ .seen = try seen(io, tmp.dir) });
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, file_name, .{}));
    var whole = try read(gpa, io, tmp.dir, .sha1);
    defer whole.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), whole.count());
}

test "the shallow file is read as git's is_repository_shallow reads it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = "1111111111111111111111111111111111111111";
    const b = "2222222222222222222222222222222222222222";
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = a ++ "\r\n" ++ b ++ " trailing" });
    var set = try read(gpa, io, tmp.dir, .sha1);
    defer set.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), set.count());
    for ([_][]const u8{ a ++ "\n\n", "\n", a[0..39] ++ "\n", "g" ++ a[1..] ++ "\n" }) |text| {
        try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = text });
        try std.testing.expectError(error.MalformedShallowFile, read(gpa, io, tmp.dir, .sha1));
    }
}
