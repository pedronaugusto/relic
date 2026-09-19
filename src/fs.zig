//! The file protocol git uses, and nothing else.
//!
//! Every write in this package goes through `LockFile` or `atomicWrite`:
//! `O_CREAT|O_EXCL` on a neighbouring name, write, fsync, rename, fsync the
//! directory where the platform has it. No advisory lock is taken anywhere,
//! because git takes none and a lock that is not the lock git holds is a lock
//! that does not stop it.
//!
//! A lock another process holds is reported, never broken. git refuses it too,
//! and breaking it is how two writers become one corrupted file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// The fields git's index carries about a file, and the ones a stat shortcut
/// compares.
///
/// `dev`, `uid` and `gid` are carried so an index git wrote round-trips byte
/// for byte. They are not observed: `std.Io` reports size, modification time,
/// status-change time, inode and permissions, and not those three, so an entry
/// this package creates carries zero in them and `matches` ignores them. That
/// is what `core.checkStat = minimal` means, stated here rather than
/// discovered.
pub const Stat = struct {
    ctime_sec: u32 = 0,
    ctime_nsec: u32 = 0,
    mtime_sec: u32 = 0,
    mtime_nsec: u32 = 0,
    dev: u32 = 0,
    ino: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u32 = 0,

    /// All zeros — the stat of an entry whose file has not been looked at,
    /// which is what `git update-index --cacheinfo` leaves behind.
    pub const none: Stat = .{};

    /// The fields this package can observe, taken from a `std.Io` stat.
    ///
    /// Seconds and nanoseconds are truncated to 32 bits, and the size to 32
    /// bits, because that is the width the index has for them; a file larger
    /// than 4 GiB therefore records a truncated size, exactly as git's own
    /// index does.
    pub fn fromIo(s: Io.File.Stat) Stat {
        const mtime = s.mtime.toNanoseconds();
        const ctime = s.ctime.toNanoseconds();
        return .{
            .ctime_sec = splitSec(ctime),
            .ctime_nsec = splitNsec(ctime),
            .mtime_sec = splitSec(mtime),
            .mtime_nsec = splitNsec(mtime),
            .ino = @truncate(@as(u64, @bitCast(@as(i64, @intCast(@min(s.inode, std.math.maxInt(i64))))))),
            .size = @truncate(s.size),
        };
    }

    /// Whether a cached stat still describes the file on the disk.
    ///
    /// Only the fields this package observes take part: modification time and
    /// size always, and the inode where both sides have one. A match means the
    /// content may be assumed unchanged — subject to the racy rule, which is
    /// the index's and not this function's.
    pub fn matches(cached: Stat, current: Stat) bool {
        if (cached.mtime_sec != current.mtime_sec) return false;
        if (cached.mtime_nsec != current.mtime_nsec) return false;
        if (cached.size != current.size) return false;
        if (cached.ino != 0 and current.ino != 0 and cached.ino != current.ino) return false;
        return true;
    }

    fn splitSec(ns: i96) u32 {
        const sec = @divFloor(ns, std.time.ns_per_s);
        if (sec < 0) return 0;
        return @truncate(@as(u96, @intCast(sec)));
    }

    fn splitNsec(ns: i96) u32 {
        const rem = @mod(ns, std.time.ns_per_s);
        return @intCast(rem);
    }
};

/// What a path on the disk turned out to be.
pub const Entry = struct {
    stat: Stat,
    kind: Io.File.Kind,
    /// Whether the owner's execute bit is set. Always false where the
    /// filesystem has no executable bit, in which case the index's mode is
    /// preserved rather than invented.
    executable: bool,
};

/// Errors from looking at a path.
pub const StatError = Io.File.OpenError || Io.File.StatError;

/// What `sub_path` is, or `null` if it is not there.
///
/// Symlinks are not followed: a symlink is a symlink, which is what a tree
/// entry with mode 120000 means.
pub fn statAt(io: Io, dir: Io.Dir, sub_path: []const u8) StatError!?Entry {
    const s = dir.statFile(io, sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => |e| return e,
    };
    return .{
        .stat = .fromIo(s),
        .kind = s.kind,
        .executable = isExecutable(s.permissions),
    };
}

/// Whether a permission set has the owner's execute bit.
pub fn isExecutable(p: Io.File.Permissions) bool {
    if (!@TypeOf(p).has_executable_bit) return false;
    return p.toMode() & 0o100 != 0;
}

/// The permissions a blob's mode asks for: 0o755 when executable, 0o644
/// otherwise, before the process umask. Where the platform has no executable
/// bit this is the default and the index's mode is what carries the truth.
pub fn permissionsFor(executable: bool) Io.File.Permissions {
    if (!Io.File.Permissions.has_executable_bit) return .default_file;
    return @enumFromInt(@as(std.posix.mode_t, if (executable) 0o777 else 0o666));
}

/// `fsync` on a directory, so a name that was created or renamed is durable.
///
/// Windows has no equivalent and this is a no-op there; the guarantee is the
/// operating system's.
pub fn syncDir(io: Io, dir: Io.Dir) Io.File.SyncError!void {
    if (builtin.os.tag == .windows) return;
    const as_file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    as_file.sync(io) catch |err| switch (err) {
        // A filesystem that refuses to sync a directory handle is not a
        // filesystem this can do anything about, and the write itself
        // already reached the disk.
        error.AccessDenied, error.Unexpected => return,
        else => |e| return e,
    };
}

/// Errors from taking a lock.
pub const LockError = error{
    /// `<path>.lock` already exists. Another writer — possibly a running git —
    /// holds it. It is never removed on your behalf; the caller decides
    /// whether to wait, to report, or to tell a person to look.
    LockHeld,
} || Io.File.OpenError;

/// Errors from finishing a lock.
pub const CommitError = Io.Writer.Error || Io.File.SyncError || Io.Dir.RenameError;

/// git's lock file: `<path>.lock`, created with `O_CREAT|O_EXCL`, written,
/// fsynced and renamed over `<path>`.
///
/// A reader of `<path>` sees either the old file or the new one and never
/// blocks. If this process dies the lock stays on the disk, exactly as git's
/// does, and the next writer reports it rather than removing it.
pub const LockFile = struct {
    dir: Io.Dir,
    /// The name being replaced, relative to `dir`. Borrowed from the caller
    /// for the lifetime of the lock.
    target: []const u8,
    /// `<target>.lock`, owned by this lock.
    lock_name: []u8,
    gpa: Allocator,
    file: Io.File,
    file_writer: Io.File.Writer,
    finished: bool = false,

    /// Take `<sub_path>.lock` in `dir`.
    ///
    /// `buffer` is this lock's write buffer and must outlive it. Returns
    /// `error.LockHeld` if the lock is already there.
    pub fn open(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        sub_path: []const u8,
        buffer: []u8,
    ) (LockError || Allocator.Error)!LockFile {
        const lock_name = try std.fmt.allocPrint(gpa, "{s}.lock", .{sub_path});
        errdefer gpa.free(lock_name);
        const file = dir.createFile(io, lock_name, .{
            .exclusive = true,
            .truncate = false,
            .read = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.LockHeld,
            else => |e| return e,
        };
        return .{
            .dir = dir,
            .target = sub_path,
            .lock_name = lock_name,
            .gpa = gpa,
            .file = file,
            .file_writer = file.writer(io, buffer),
        };
    }

    /// The writer the new contents go through.
    pub fn writer(lock: *LockFile) *Io.Writer {
        return &lock.file_writer.interface;
    }

    /// Flush, fsync, close and rename over the target, then fsync the
    /// directory. After this the lock is gone and the new bytes are the file.
    pub fn commit(lock: *LockFile, io: Io) CommitError!void {
        std.debug.assert(!lock.finished);
        try lock.file_writer.interface.flush();
        try lock.file.sync(io);
        lock.file.close(io);
        lock.finished = true;
        try lock.dir.rename(lock.lock_name, lock.dir, lock.target, io);
        try syncDir(io, lock.dir);
    }

    /// Give the lock up, leaving the target as it was. Safe to call after
    /// `commit`, which is what makes `defer lock.deinit(io)` the right shape.
    pub fn deinit(lock: *LockFile, io: Io) void {
        if (!lock.finished) {
            lock.file.close(io);
            lock.dir.deleteFile(io, lock.lock_name) catch {};
            lock.finished = true;
        }
        lock.gpa.free(lock.lock_name);
        lock.* = undefined;
    }
};

/// Whether `<sub_path>.lock` exists in `dir`.
///
/// A caller that wants to say "another process is writing this" before doing
/// any work asks here. It is a report and never a removal.
pub fn lockHeld(io: Io, dir: Io.Dir, sub_path: []const u8) bool {
    var buf: [max_name]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}.lock", .{sub_path}) catch return false;
    dir.access(io, name, .{}) catch return false;
    return true;
}

const max_name = 512;

/// Errors from replacing a file whole.
pub const AtomicWriteError = Io.File.OpenError || Io.Writer.Error ||
    Io.File.SyncError || Io.Dir.RenameError || Io.Dir.DeleteFileError;

/// Replace `sub_path` with `bytes` through a uniquely-named neighbour.
///
/// Used where git writes a temporary rather than a `.lock` — a loose object,
/// whose name nobody waits on — so two writers of the same object never meet.
pub fn atomicWrite(
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    bytes: []const u8,
    prefix: []const u8,
) AtomicWriteError!void {
    var name_buf: [max_name]u8 = undefined;
    const temp = tempName(&name_buf, prefix);
    var file = try dir.createFile(io, temp, .{ .exclusive = true });
    errdefer {
        file.close(io);
        dir.deleteFile(io, temp) catch {};
    }
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &write_buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
    try file.sync(io);
    file.close(io);
    dir.rename(temp, dir, sub_path, io) catch |err| {
        dir.deleteFile(io, temp) catch {};
        return err;
    };
    try syncDir(io, dir);
}

/// A name no other process will pick, written into `buf`.
///
/// Randomness comes from the operating system, not from a clock: rule 5 holds
/// even here.
pub fn tempName(buf: []u8, prefix: []const u8) []const u8 {
    var raw: [12]u8 = undefined;
    std.crypto.random.bytes(&raw);
    var hex: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&raw}) catch unreachable;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, hex }) catch unreachable;
}

/// Read a whole file, or `null` if it is not there.
///
/// The returned bytes are the caller's. `max_bytes` bounds the allocation, so
/// a hostile or corrupt path cannot ask for the address space.
pub fn readFileAlloc(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    max_bytes: usize,
) (Io.Dir.ReadFileAllocError)!?[]u8 {
    return dir.readFileAlloc(io, sub_path, gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return null,
        else => |e| return e,
    };
}

/// Join path components with `/`, which is the separator every git format
/// uses whatever the platform underneath. The result is the caller's.
pub fn join(gpa: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    var total: usize = 0;
    var count: usize = 0;
    for (parts) |p| {
        if (p.len == 0) continue;
        if (count != 0) total += 1;
        total += p.len;
        count += 1;
    }
    const out = try gpa.alloc(u8, total);
    var i: usize = 0;
    var first = true;
    for (parts) |p| {
        if (p.len == 0) continue;
        if (!first) {
            out[i] = '/';
            i += 1;
        }
        @memcpy(out[i..][0..p.len], p);
        i += p.len;
        first = false;
    }
    return out;
}

/// Whether a path component is one a repository must never follow: `.`, `..`,
/// `.git` in any case a case-insensitive filesystem would fold, and the NTFS
/// short name `git~1`.
///
/// Checked on the way in from a tree and on the way out to the disk, because a
/// tree is a file format and anyone may write one.
pub fn isDangerousComponent(name: []const u8) bool {
    if (name.len == 0) return true;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return true;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return true;
    if (name.len == 4 and std.ascii.eqlIgnoreCase(name, ".git")) return true;
    if (name.len == 5 and std.ascii.eqlIgnoreCase(name, "git~1")) return true;
    // Trailing dots and spaces are stripped by Windows, so `.git.` opens
    // `.git`.
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') {
        var end = name.len;
        while (end > 0 and (name[end - 1] == '.' or name[end - 1] == ' ')) end -= 1;
        if (end == 4 and std.ascii.eqlIgnoreCase(name[0..4], ".git")) return true;
    }
    return false;
}

/// Whether a whole `/`-separated path is safe to write into a working tree.
pub fn isSafePath(path: []const u8) bool {
    if (path.len == 0) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (isDangerousComponent(component)) return false;
    }
    return true;
}

test "a lock is refused, not broken" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.writeFile(io, .{ .sub_path = "thing", .data = "old\n" });

    var buf: [64]u8 = undefined;
    var lock = try LockFile.open(gpa, io, dir, "thing", &buf);
    defer lock.deinit(io);

    var buf2: [64]u8 = undefined;
    try std.testing.expectError(
        error.LockHeld,
        LockFile.open(gpa, io, dir, "thing", &buf2),
    );
    try std.testing.expect(lockHeld(io, dir, "thing"));

    // The contended attempt left the lock exactly as it found it.
    try lock.writer().writeAll("new\n");
    try lock.commit(io);

    var read_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("new\n", try dir.readFile(io, "thing", &read_buf));
    try std.testing.expect(!lockHeld(io, dir, "thing"));
}

test "a rolled-back lock changes nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.writeFile(io, .{ .sub_path = "thing", .data = "old\n" });
    {
        var buf: [64]u8 = undefined;
        var lock = try LockFile.open(gpa, io, dir, "thing", &buf);
        defer lock.deinit(io);
        try lock.writer().writeAll("never\n");
    }
    var read_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("old\n", try dir.readFile(io, "thing", &read_buf));
    try std.testing.expect(!lockHeld(io, dir, "thing"));
}

test "dangerous components are refused" {
    try std.testing.expect(isDangerousComponent(".git"));
    try std.testing.expect(isDangerousComponent(".GIT"));
    try std.testing.expect(isDangerousComponent(".Git."));
    try std.testing.expect(isDangerousComponent("git~1"));
    try std.testing.expect(isDangerousComponent(".."));
    try std.testing.expect(!isDangerousComponent(".gitignore"));
    try std.testing.expect(!isSafePath("a/.git/b"));
    try std.testing.expect(isSafePath("a/b/c"));
}
