//! The file protocol git uses, and nothing else.
//!
//! Every replacement goes through `LockFile` or `atomicWrite`:
//! `O_CREAT|O_EXCL` on a neighbouring name, write, make durable as the policy
//! asks, rename. No advisory lock is taken anywhere, because git takes none
//! and a lock that is not the lock git holds is a lock that does not stop it.
//!
//! A lock another process holds is reported, never broken — with the holder's
//! process id where it can be found, which is what git itself now writes.

const Self = @This();

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const platstat = @import("stat.zig");
const conduit = @import("conduit");

/// The end-of-operation policy for selected objects and checkout.
pub const Durability = enum { none, durable };
const airlock = @import("airlock");
/// A requested durability level was refused by the filesystem.
pub const SyncError = airlock.DirSyncError || airlock.SyncPathError || error{LevelUnavailable};

fn syncFileLevel(io: Io, file: Io.File, level: airlock.Level) SyncError!void {
    const reached = try airlock.syncFile(io, file, .{ .level = level });
    if (!reached.atLeast(level)) return error.LevelUnavailable;
}

pub const FileSyncOptions = struct { policy: Sync = .per_file };

/// Sync an open descriptor under relic's policy, refusing a weaker level.
/// Batch writes request ordering; the operation's final barrier requests data.
pub fn syncFile(io: Io, file: Io.File, options: FileSyncOptions) SyncError!void {
    switch (options.policy) {
        .none => {},
        .batch => try syncFileLevel(io, file, .ordered),
        .per_file => try syncFileLevel(io, file, .data),
    }
}

pub fn syncPath(io: Io, dir: Io.Dir, path: []const u8) SyncError!void {
    const reached = try airlock.syncPath(io, dir, path, .{ .level = .data });
    if (!reached.atLeast(.data)) return error.LevelUnavailable;
}

pub fn syncDirectory(io: Io, dir: Io.Dir, path: []const u8) SyncError!void {
    const opened = try dir.openDir(io, path, .{});
    defer opened.close(io);
    try syncDir(io, opened);
}

/// How hard a write is pushed towards the disk.
///
/// git's own default is looser than it looks: `core.fsync` defaults to
/// `committed,-loose-object`, so stock git makes neither a loose object nor
/// the index durable before returning. The cost of the strict choice is
/// measurable — a single `fsync` per object turns a three-thousand-file `add`
/// into seconds of waiting — so it is a policy here and not a constant.
pub const Sync = enum {
    /// Write and rename. The operating system decides when the bytes land.
    /// This is git's default for loose objects.
    none,
    /// Flush each file towards the disk, and put one real barrier at the end
    /// of a batch. This is git's `core.fsyncMethod = batch`: the barrier is a
    /// throwaway file in the same directory, synced and then removed, which
    /// makes every file flushed before it durable at the cost of one sync
    /// rather than one per file.
    batch,
    /// Sync every file before its rename. The strictest and the slowest.
    per_file,

    /// git's own default for the objects and the index: neither is synced.
    pub const default: Sync = .none;
};

/// How fine a modification time a filesystem records.
///
/// The old assumption here was that a nanosecond reported is a nanosecond
/// kept. It is not: APFS and ext4 keep nanoseconds, HFS+ and most network
/// filesystems keep whole seconds, and several keep something between. Both
/// ends of that are wrong to assume. Believing nanoseconds a filesystem does
/// not keep makes every entry look changed; ignoring nanoseconds a
/// filesystem does keep throws away the precision that tells a rewritten
/// file from an untouched one inside the same second.
///
/// So it is measured, once, where the file being compared lives.
pub const Resolution = struct {
    /// The smallest unit every modification time seen was a multiple of.
    /// One means every nanosecond is kept.
    ns: u64 = 1,
    /// Whether this was measured or assumed. An unmeasured resolution is
    /// what a directory nothing could be written into leaves behind.
    measured: bool = false,

    /// Every nanosecond kept, which is what this package assumed before it
    /// measured.
    pub const nanosecond: Resolution = .{ .ns = 1 };
    /// Whole seconds only, which is what a filesystem that reports zero
    /// nanoseconds has.
    pub const second: Resolution = .{ .ns = std.time.ns_per_s };

    /// Whether the filesystem keeps anything below a second.
    pub fn hasSubsecond(r: Resolution) bool {
        return r.ns < std.time.ns_per_s;
    }

    /// Two nanosecond fields, as the filesystem can tell them apart.
    fn sameSubsecond(r: Resolution, a: u32, b: u32) bool {
        if (!r.hasSubsecond()) return true;
        return a / r.ns == b / r.ns;
    }
};

/// Measure how fine a modification time `dir`'s filesystem records.
///
/// One file is created there, written to three times, and stat'd after each
/// write; the answer is the largest power of ten that divides every
/// nanosecond field reported, capped at a second. A filesystem that keeps
/// whole seconds reports zero every time and is a second; one that keeps
/// milliseconds reports multiples of a million; one that keeps nanoseconds
/// reports three values whose only common divisor is one.
///
/// Three samples is what makes the answer trustworthy: a filesystem that
/// keeps nanoseconds would have to report three times that are all multiples
/// of the same round number for this to say otherwise.
///
/// A directory nothing can be written into gives `Resolution.nanosecond`
/// with `measured` false, which is the assumption this replaces and the
/// lenient answer of the two.
pub fn probeTimestampResolution(io: Io, dir: Io.Dir) Resolution {
    var name_buf: [64]u8 = undefined;
    const name = tempName(io, &name_buf, "relic_tres_");
    // The handle is opened for reading as well as writing because the stat
    // below is taken through it: Windows grants a write-only handle no right
    // to read the file's attributes, so `stat` there is `AccessDenied` and
    // the measurement never happens.
    const file = dir.createFile(io, name, .{ .exclusive = true, .read = true }) catch
        return .nanosecond;
    defer {
        file.close(io);
        dir.deleteFile(io, name) catch {};
    }

    var divisor: u64 = 0;
    var samples: u8 = 0;
    for (0..3) |_| {
        file.writeStreamingAll(io, "relic") catch break;
        // Windows does not put a write's time on the file while the handle
        // that made it is still open: without this every sample would be the
        // time the file was created and the answer would be of nothing.
        // A write whose time cannot be put on the file is a sample not taken.
        if (builtin.target.os.tag == .windows) syncFile(io, file, .{ .policy = .per_file }) catch break;
        const s = file.stat(io) catch break;
        const nsec: u64 = @intCast(@mod(s.mtime.toNanoseconds(), std.time.ns_per_s));
        divisor = std.math.gcd(divisor, nsec);
        samples += 1;
    }
    if (samples == 0) return .nanosecond;
    // Every sample reported zero: the filesystem keeps seconds and nothing
    // below them. That is a measurement and not an assumption, so it says so.
    if (divisor == 0) return .{ .ns = std.time.ns_per_s, .measured = true };

    var unit: u64 = std.time.ns_per_s;
    while (unit > 1 and divisor % unit != 0) unit /= 10;
    // A power of ten no coarser than a second, which is what a stat
    // comparison rounds a nanosecond field down to.
    assert(std.time.ns_per_s % unit == 0);
    return .{ .ns = unit, .measured = true };
}

/// The fields git's index carries about a file, and the ones a stat shortcut
/// compares.
pub const Stat = struct {
    ctime_sec: u32 = 0,
    ctime_nsec: u32 = 0,
    mtime_sec: u32 = 0,
    mtime_nsec: u32 = 0,
    dev: u32 = 0,
    ino: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    /// Truncated to 32 bits, which is the width the index has. A file larger
    /// than four gigabytes therefore records a truncated size, exactly as
    /// git's own index does.
    size: u32 = 0,

    /// All zeros — the stat of an entry whose file has not been looked at,
    /// which is what `git update-index --cacheinfo` leaves behind.
    pub const none: Stat = .{};

    /// Take the fields `std.Io` reports, and the three it does not from the
    /// platform.
    pub fn fromIo(s: Io.File.Stat, extra: platstat.Extra) Stat {
        return fromParts(
            s.mtime.toNanoseconds(),
            s.ctime.toNanoseconds(),
            @bitCast(@as(i64, @intCast(s.inode))),
            s.size,
            extra,
        );
    }

    /// Take every field from one platform stat.
    pub fn fromFull(f: platstat.Full) Stat {
        return fromParts(@intCast(f.mtime_ns), @intCast(f.ctime_ns), f.inode, f.size, f.extra);
    }

    fn fromParts(mtime: i96, ctime: i96, inode: u64, size: u64, extra: platstat.Extra) Stat {
        return .{
            .ctime_sec = splitSec(ctime),
            .ctime_nsec = splitNsec(ctime),
            .mtime_sec = splitSec(mtime),
            .mtime_nsec = splitNsec(mtime),
            .dev = extra.dev,
            .ino = @truncate(inode),
            .uid = extra.uid,
            .gid = extra.gid,
            .size = @truncate(size),
        };
    }

    /// How much of a stat to believe.
    ///
    /// git's `core.checkStat`, with the same two values and the same
    /// meaning. `full` is git's default on every platform but Windows.
    pub const Check = enum {
        /// Modification time, size, and the inode, owner and device where
        /// both sides report them.
        full,
        /// Modification time and size only. What to use on a filesystem
        /// whose inode numbers or owners are not stable.
        minimal,
    };

    /// Whether a cached stat still describes the file on the disk.
    ///
    /// The status-change time is never compared. git compares it only under
    /// `core.trustCtime`, and a machine running a desktop search indexer
    /// changes it without the content changing.
    ///
    /// `resolution` is how fine a modification time the filesystem keeps,
    /// which decides how much of the nanosecond field means anything. A
    /// recorded zero on either side is still treated as "no nanoseconds
    /// here", because that is what an index written by an implementation
    /// without them looks like and re-hashing a whole working tree over it
    /// would be a poor trade.
    pub fn matches(cached: Stat, current: Stat, check: Check, resolution: Resolution) bool {
        if (cached.mtime_sec != current.mtime_sec) return false;
        if (cached.mtime_nsec != 0 and current.mtime_nsec != 0 and
            !resolution.sameSubsecond(cached.mtime_nsec, current.mtime_nsec)) return false;
        if (cached.size != current.size) return false;
        if (check == .minimal) return true;
        if (cached.ino != 0 and current.ino != 0 and cached.ino != current.ino) return false;
        if (cached.uid != current.uid or cached.gid != current.gid) return false;
        // `st_dev` is deliberately not compared. git leaves it out of the
        // default comparison too, because it changes under a caller on a
        // network filesystem without anything about the file changing.
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
///
/// One call where the platform reports all of it, two where it does not. A
/// walk over a working tree asks this once per entry, so the difference is a
/// syscall per file.
pub fn statAt(io: Io, dir: Io.Dir, sub_path: []const u8) Self.StatError!?Entry {
    switch (platstat.full(dir, sub_path)) {
        .absent => return null,
        .found => |f| return .{
            .stat = .fromFull(f),
            .kind = f.kind,
            .executable = f.mode & 0o100 != 0,
        },
        // Either the platform has no such call, or it failed for a reason the
        // caller should see named rather than guessed at. `std.Io` names it.
        .unavailable => {},
    }
    const s = dir.statFile(io, sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => |e| return e,
    };
    return .{
        .stat = .fromIo(s, platstat.statAt(dir, sub_path)),
        .kind = s.kind,
        .executable = isExecutable(s.permissions),
    };
}

/// Whether a permission set has the owner's execute bit.
///
/// Only the owner's bit counts, which is what git compares.
pub fn isExecutable(p: Io.File.Permissions) bool {
    if (!@TypeOf(p).has_executable_bit) return false;
    return p.toMode() & 0o100 != 0;
}

/// The process's umask, as git reads it for `tar.umask=user`: set to zero
/// and put back at once, the only way POSIX gives to read it, so a file
/// another thread creates in that moment is made without it. Windows has
/// no umask, and git there reads zero.
pub fn processUmask() u32 {
    switch (builtin.target.os.tag) {
        .windows => return 0,
        .linux => if (!builtin.link_libc) {
            const linux = std.os.linux;
            const old = linux.syscall1(.umask, 0);
            _ = linux.syscall1(.umask, old);
            return @intCast(old & 0o7777);
        },
        else => {},
    }
    const old = std.c.umask(0);
    _ = std.c.umask(old);
    return @intCast(old & 0o7777);
}

/// The permissions a blob's mode asks for: 0o777 when executable, 0o666
/// otherwise, before the process umask — which is what git creates files
/// with. Where the platform has no executable bit this is the default and
/// the index's mode is what carries the truth.
pub fn permissionsFor(executable: bool) Io.File.Permissions {
    if (!Io.File.Permissions.has_executable_bit) return .default_file;
    return @fromBackingInt(@intCast(@as(std.posix.mode_t, if (executable) 0o777 else 0o666)));
}

/// Whether directory entries are made durable after a rename.
///
/// Off by default, and on by request for a caller who wants the renamed
/// entry flushed as well as the file's bytes. This uses plain `fsync`, with
/// the same macOS writeout policy as file syncs; the batch barrier remains
/// the place for the drive-cache flush. Windows cannot flush directory
/// handles with `FlushFileBuffers`, so this is a no-op there.
pub const sync_directories_default = false;

/// `fsync` on a directory, so a name that was created or renamed is durable.
///
/// Windows's `FlushFileBuffers` does not support directory handles, so this
/// is a no-op there; the guarantee is the operating system's.
/// On Linux `dir` must have been opened with `iterate = true`: otherwise
/// Zig uses `O_PATH`, whose handle cannot be synced.
pub fn syncDir(io: Io, dir: Io.Dir) SyncError!void {
    const reached = try airlock.syncDir(io, dir, .{ .level = .data });
    if (!reached.atLeast(.data)) return error.LevelUnavailable;
}

/// Put one durability barrier at the end of a batch of writes.
///
/// git's own method: create a throwaway file in the same directory, sync it,
/// and remove it. Everything flushed into the same writeback cache before it
/// is durable once it returns, at the cost of one sync instead of one per
/// file. On macOS that is the difference between milliseconds and seconds.
pub const BarrierError = Io.File.OpenError || SyncError;

pub fn syncBarrier(io: Io, dir: Io.Dir) BarrierError!void {
    var name_buf: [64]u8 = undefined;
    const name = tempName(io, &name_buf, "relic_fsync_");
    return syncBarrierNamed(io, dir, name);
}

fn syncBarrierNamed(io: Io, dir: Io.Dir, name: []const u8) (Io.File.OpenError || SyncError)!void {
    const file = try dir.createFile(io, name, .{ .exclusive = true });
    defer {
        file.close(io);
        dir.deleteFile(io, name) catch {};
    }
    try syncFileLevel(io, file, .data);
}

/// What to do when the lock is already held.
pub const OnContention = union(enum) {
    /// Return `error.LockHeld` at once. What a caller that has something
    /// better to do wants.
    fail,
    /// Retry with a quadratic backoff starting at one millisecond and capped
    /// at a thousandfold, each wait spread a quarter either way, for up to
    /// this many milliseconds in total. git's own constants.
    wait_ms: u32,
};

/// Errors from taking a lock.
pub const LockError = error{
    /// `<path>.lock` already exists. Another writer — possibly a running git
    /// — holds it. It is never removed on your behalf; `staleReport` says
    /// what can be found out about the holder.
    LockHeld,
} || Io.File.OpenError || Io.Cancelable;

/// Errors from finishing a lock.
pub const CommitError = Io.Writer.Error || SyncError || Io.Dir.RenameError || Io.Dir.OpenError || Io.File.SetLengthError;

/// git's lock file: `<path>.lock`, created with `O_CREAT|O_EXCL`, written,
/// made durable as the policy asks, and renamed over `<path>`.
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
    /// How many bytes of `pid <n>` the lock holds until its contents are
    /// written, zero when it holds none.
    pid_len: u8 = 0,
    gpa: Allocator,
    file: Io.File,
    file_writer: Io.File.Writer,
    sync: Sync,
    sync_directory: bool,
    finished: bool = false,

    /// How a lock is taken.
    pub const Options = struct {
        /// What to do when the lock is already held.
        on_contention: OnContention = .fail,
        /// How hard to push the new bytes towards the disk before the
        /// rename. A lock is how a file is replaced, so the default here is
        /// stricter than for a loose object: the failures this prevents —
        /// an empty ref, a truncated index — are the ones the field actually
        /// reports.
        sync: Sync = .per_file,
        /// Whether the lock names this process while it is held, so that a
        /// later writer that meets it can say who holds it (`staleReport`).
        /// The name is the lock's own first bytes, `pid <n>`, which the new
        /// contents then write over: no reader of the file the lock
        /// replaces ever sees them, git reads nothing from a lock, and it
        /// costs one write rather than a file of its own beside each lock.
        write_pid: bool = true,
        /// Sync the target's parent directory after the commit rename, so
        /// the new name is flushed too. Independent of the file sync policy.
        /// A no-op on Windows: `FlushFileBuffers` cannot flush directories.
        sync_directory: bool = sync_directories_default,
        /// The permissions `core.sharedRepository` asks for, given to the
        /// lock, and so to the file it becomes, as git's tempfiles get them.
        shared: Shared = .umask,
    };

    /// Errors from `open`.
    pub const OpenError = LockError || Allocator.Error;

    /// Take `<sub_path>.lock` in `dir`.
    ///
    /// `buffer` is this lock's write buffer and must outlive it.
    pub fn open(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        sub_path: []const u8,
        buffer: []u8,
        options: Options,
    ) OpenError!LockFile {
        const lock_name = try gpa.print("{s}.lock", .{sub_path});
        errdefer gpa.free(lock_name);

        const file = try createExclusive(io, dir, lock_name, options.on_contention);
        errdefer {
            file.close(io);
            dir.deleteFile(io, lock_name) catch {};
        }
        adjustShared(io, dir, lock_name, options.shared);

        var pid_len: u8 = 0;
        if (options.write_pid) {
            var text: [32]u8 = undefined;
            // unreachable: a u32 pid is at most ten digits
            const line = std.mem.print(&text, "pid {d}\n", .{currentPid()}) catch unreachable;
            // Only a name for a report: a lock that could not say it is
            // still the lock.
            if (file.writePositionalAll(io, line, 0)) |_| {
                pid_len = @intCast(line.len);
            } else |_| {}
        }

        return .{
            .dir = dir,
            .target = sub_path,
            .lock_name = lock_name,
            .pid_len = pid_len,
            .gpa = gpa,
            .file = file,
            .file_writer = file.writer(io, buffer),
            .sync = options.sync,
            .sync_directory = options.sync_directory,
        };
    }

    /// The writer the new contents go through.
    pub fn writer(lock: *LockFile) *Io.Writer {
        return &lock.file_writer.interface;
    }

    /// Flush, make durable, close and rename over the target. After this the
    /// lock is gone and the new bytes are the file.
    pub fn commit(lock: *LockFile, io: Io) Self.CommitError!void {
        assert(!lock.finished);
        try lock.file_writer.interface.flush();
        // Contents shorter than the `pid` line under them leave its tail.
        if (lock.file_writer.pos < lock.pid_len) try lock.file.setLength(io, lock.file_writer.pos);
        switch (lock.sync) {
            .none => {},
            // Both arms sync the lock's own descriptor before the rename,
            // which is the step that prevents every corruption the field
            // reports: an empty ref, a truncated index, a zero-length loose
            // object. A batch differs from a per-file sync in what happens
            // at the end of the batch, not here.
            .batch => try syncFileLevel(io, lock.file, .ordered),
            .per_file => try syncFileLevel(io, lock.file, .data),
        }
        lock.file.close(io);
        lock.finished = true;
        renameWithRetry(io, lock.dir, lock.lock_name, lock.target) catch |err| {
            // ziglint-ignore: Z026 the rename's error is the one to report; a lock left behind is what git reports as held, naming the file to remove
            lock.dir.deleteFile(io, lock.lock_name) catch {};
            return err;
        };
        if (lock.sync_directory) {
            // `target` may be refs/heads/main relative to the repository:
            // it is heads, not the repository directory, that was changed.
            // Linux's non-iterable directory handles use O_PATH, which
            // fsync cannot use. Open for reading even when this is `dir`.
            const parent = std.Io.Dir.path.dirname(lock.target) orelse ".";
            const dir = try lock.dir.openDir(io, parent, .{ .iterate = true });
            defer dir.close(io);
            try syncDir(io, dir);
        }
    }

    /// Give the lock up, leaving the target as it was. Safe to call after
    /// `commit`, which is what makes `defer lock.deinit(io)` the right shape.
    pub fn deinit(lock: *LockFile, io: Io) void {
        if (!lock.finished) {
            lock.file.close(io);
            // ziglint-ignore: Z026 giving a lock up cannot fail; a lock left behind is what git reports as held, naming the file to remove
            lock.dir.deleteFile(io, lock.lock_name) catch {};
            lock.finished = true;
        }
        lock.gpa.free(lock.lock_name);
        lock.* = undefined;
    }
};

fn createExclusive(
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    on_contention: OnContention,
) LockError!Io.File {
    const deadline_ms: u32 = switch (on_contention) {
        .fail => 0,
        .wait_ms => |ms| ms,
    };
    var waited: u32 = 0;
    var attempt: u32 = 0;
    while (true) {
        if (dir.createFile(io, name, .{ .exclusive = true, .truncate = false, .read = true })) |file| {
            return file;
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            // Windows hands back a sharing violation as access denied when
            // an indexer or a scanner holds the file between the write and
            // the rename. Two independent implementations settled on the
            // same answer: retry briefly.
            error.AccessDenied, error.PermissionDenied => if (builtin.target.os.tag != .windows) return err,
            else => return err,
        }
        if (waited >= deadline_ms) return error.LockHeld;
        var jitter: [2]u8 = undefined;
        io.random(&jitter);
        const delay = backoffMs(attempt, std.mem.readInt(u16, &jitter, .little));
        try Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(delay), .clock = .awake } }, io);
        waited +|= @intCast(delay);
        attempt += 1;
    }
}

/// git's backoff, from `lock_file_timeout`: the attempt number squared, in
/// milliseconds, capped at a thousand, and each wait somewhere between
/// three quarters and five quarters of that so that two waiters do not
/// retry in step. `random` picks where.
fn backoffMs(attempt: u32, random: u16) i64 {
    const n: u64 = @as(u64, attempt) + 1;
    const multiplier: u64 = @min(n * n, 1000);
    const spread: u64 = 750 + @as(u64, random % 500);
    return @intCast(@max(1, spread * multiplier / 1000));
}

test "the backoff grows as git's does, by squares to a second, with spread" {
    try std.testing.expectEqual(@as(i64, 1), backoffMs(0, 250));
    try std.testing.expectEqual(@as(i64, 4), backoffMs(1, 250));
    try std.testing.expectEqual(@as(i64, 9), backoffMs(2, 250));
    try std.testing.expectEqual(@as(i64, 1000), backoffMs(40, 250));
    try std.testing.expectEqual(@as(i64, 750), backoffMs(40, 0));
    try std.testing.expectEqual(@as(i64, 1249), backoffMs(40, 499));
}

/// Rename, retrying briefly on Windows.
///
/// Antivirus and the search indexer hold a handle between the write and the
/// rename, and ten attempts at five milliseconds apart is what the field has
/// settled on. Elsewhere the first attempt is the only one.
pub fn renameWithRetry(io: Io, dir: Io.Dir, old_name: []const u8, new_name: []const u8) Io.Dir.RenameError!void {
    if (builtin.target.os.tag != .windows) {
        return dir.rename(old_name, dir, new_name, io);
    }
    var attempts: u8 = 0;
    var cleared = false;
    while (true) {
        if (dir.rename(old_name, dir, new_name, io)) {
            return;
        } else |err| switch (err) {
            error.AccessDenied, error.PermissionDenied, error.FileBusy => {
                // A read-only file — a lockable one nobody holds the lock
                // on — cannot be replaced until the attribute is off, which
                // git for Windows takes off too.
                if (!cleared) {
                    cleared = true;
                    if (clearReadOnly(io, dir, new_name)) continue;
                }
                attempts += 1;
                if (attempts >= 10) return err;
                Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }, io) catch return err;
            },
            else => return err,
        }
    }
}

/// Take off `sub_path`'s read-only attribute, when it has one, as git for
/// Windows does before it replaces or removes a file. Returns whether it
/// did. Elsewhere a file's own write bits do not stop either, and this does
/// nothing.
fn clearReadOnly(io: Io, dir: Io.Dir, sub_path: []const u8) bool {
    if (builtin.target.os.tag != .windows) return false;
    const st = dir.statFile(io, sub_path, .{}) catch return false;
    if (!isReadOnly(st.permissions)) return false;
    setFilePermissions(io, dir, sub_path, withReadOnly(st.permissions, false)) catch return false;
    return true;
}

/// Whether nobody may write the file: no write bit at all, or Windows's
/// read-only attribute. The standard library's own test for it does not
/// compile for Windows in 0.16.
pub fn isReadOnly(p: Io.File.Permissions) bool {
    if (builtin.target.os.tag == .windows) return @backingInt(p) & 1 != 0;
    if (!Io.File.Permissions.has_executable_bit) return false;
    return p.toMode() & 0o222 == 0;
}

/// `p` with every write bit taken away, or the owner's given back — git-lfs's
/// two moves for a lockable file — or Windows's read-only attribute set or
/// cleared.
pub fn withReadOnly(p: Io.File.Permissions, read_only: bool) Io.File.Permissions {
    if (builtin.target.os.tag == .windows) {
        const attributes: u32 = @backingInt(p);
        if (read_only) return @fromBackingInt(@intCast(attributes | 1));
        // No attributes at all is written as `FILE_ATTRIBUTE_NORMAL`: to
        // `NtSetInformationFile` a zero means "leave them as they are".
        const cleared = attributes & ~@as(u32, 1);
        return @fromBackingInt(@intCast(if (cleared == 0) 0x80 else cleared));
    }
    if (!Io.File.Permissions.has_executable_bit) return p;
    const mode = p.toMode();
    return .fromMode(if (read_only) mode & ~@as(std.posix.mode_t, 0o222) else mode | 0o200);
}

/// What `core.sharedRepository` asks of the permissions of what a
/// repository writes: git's `PERM_*` values.
pub const Shared = union(enum) {
    /// `umask`, `false`, `0`: as the process umask leaves them.
    umask,
    /// `group`, `true`, `1`: read and write for the group too.
    group,
    /// `all`, `world`, `everybody`, `2`: and read for everyone.
    everybody,
    /// `0xxx`: exactly these bits, the owner always reading and writing.
    mode: u16,

    /// Errors from reading the setting.
    pub const ParseError = error{
        /// An octal mode that leaves the owner unable to read or write.
        InvalidSharedMode,
    };

    /// git's `git_config_perm` for `value`, `null` being the setting
    /// written with no value.
    pub fn parse(value: ?[]const u8) Shared.ParseError!Shared {
        const text = value orelse return .group;
        if (std.mem.eql(u8, text, "umask")) return .umask;
        if (std.mem.eql(u8, text, "group")) return .group;
        if (std.mem.eql(u8, text, "all") or std.mem.eql(u8, text, "world") or std.mem.eql(u8, text, "everybody")) return .everybody;
        const n = parseOctalPrefix(text) orelse return if (truthy(text)) .group else .umask;
        return switch (n) {
            0 => .umask,
            1 => .group,
            2 => .everybody,
            else => {
                if (n & 0o600 != 0o600) return error.InvalidSharedMode;
                // others never write
                const mode: u16 = @intCast(n & 0o666);
                // What `calc` builds on: the owner reads and writes, and
                // nobody is given execute, which `calc` copies from the file.
                assert(mode & 0o600 == 0o600);
                assert(mode & 0o111 == 0);
                return .{ .mode = mode };
            },
        };
    }

    /// C's `strtol(text, &end, 8)` with nothing left after the number.
    fn parseOctalPrefix(text: []const u8) ?u32 {
        var i: usize = 0;
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        var neg = false;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) {
            neg = text[i] == '-';
            i += 1;
        }
        const start = i;
        var n: u32 = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '7') : (i += 1) n = n *% 8 +% (text[i] - '0');
        if (i != text.len) return null;
        if (i == start) return if (text.len == 0) 0 else null;
        return if (neg) 0 else n;
    }

    /// git's `git_config_bool` for a value that is not a number.
    fn truthy(text: []const u8) bool {
        for ([_][]const u8{ "true", "yes", "on" }) |word| if (std.ascii.eqlIgnoreCase(text, word)) return true;
        return false;
    }

    /// git's `calc_shared_perm`: the mode `mode` becomes.
    pub fn calc(shared: Shared, mode: u32) u32 {
        var tweak: u32 = switch (shared) {
            .umask => return mode,
            .group => 0o660,
            .everybody => 0o664,
            .mode => |m| m,
        };
        if (mode & 0o200 == 0) tweak &= ~@as(u32, 0o222);
        if (mode & 0o100 != 0) tweak |= (tweak & 0o444) >> 2;
        return switch (shared) {
            .mode => (mode & ~@as(u32, 0o777)) | tweak,
            else => mode | tweak,
        };
    }
};

/// git's `adjust_shared_perm` for `sub_path` in `dir`: its permissions as
/// `shared` asks, a directory's read bits copied to its search bits and,
/// where the group gains anything, set-group-ID set. Nothing where the
/// platform has no permission bits. Permissions are a courtesy to the
/// group, and a file system that will not set them leaves the write as it
/// was rather than failing it.
pub fn adjustShared(io: Io, dir: Io.Dir, sub_path: []const u8, shared: Shared) void {
    if (shared == .umask or !Io.File.Permissions.has_executable_bit) return;
    const found = switch (platstat.full(dir, sub_path)) {
        .found => |f| f,
        .absent, .unavailable => return,
    };
    const old = found.mode & 0o7777;
    var new = shared.calc(old);
    if (found.kind == .directory) {
        new |= (new & 0o444) >> 2;
        if (new & 0o060 != 0) new |= 0o2000;
    }
    if (new != old) dir.setFilePermissions(io, sub_path, @fromBackingInt(@intCast(@as(std.posix.mode_t, @intCast(new)))), .{}) catch return;
}

/// A file git writes read-only into `objects` — a loose object, a pack and
/// its index and reverse index, a commit-graph — given git's mode for it:
/// 0444 less the umask, then as `shared` asks. Nothing where the platform
/// has no permission bits.
pub fn readOnlyObject(io: Io, dir: Io.Dir, sub_path: []const u8, shared: Shared) void {
    if (!Io.File.Permissions.has_executable_bit) return;
    const mode: u32 = 0o444 & ~processUmask();
    dir.setFilePermissions(io, sub_path, @fromBackingInt(@intCast(@as(std.posix.mode_t, @intCast(mode)))), .{}) catch return;
    adjustShared(io, dir, sub_path, shared);
}

/// Make `sub_path` and the directories above it in `dir`, each one this
/// makes given `shared`'s permissions: git's
/// `safe_create_leading_directories` for a path in a repository.
pub fn makeDirs(io: Io, dir: Io.Dir, sub_path: []const u8, shared: Shared) Io.Dir.CreateDirPathError!void {
    if (shared == .umask) return dir.createDirPath(io, sub_path);
    var end: usize = 0;
    while (end < sub_path.len) {
        end = std.mem.findAnyPos(u8, sub_path, end + 1, "/\\") orelse sub_path.len;
        const part = sub_path[0..end];
        if (dir.createDir(io, part, .default_dir)) |_| {
            adjustShared(io, dir, part, shared);
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        }
    }
}

/// `Dir.setFilePermissions`, on Windows as well, where the standard
/// library's has no implementation in 0.17: there the file's attributes are
/// written through a handle opened for nothing else, which Windows grants
/// on a read-only file too.
pub fn setFilePermissions(io: Io, dir: Io.Dir, sub_path: []const u8, permissions: Io.File.Permissions) Io.Dir.SetFilePermissionsError!void {
    if (builtin.target.os.tag != .windows) return dir.setFilePermissions(io, sub_path, permissions, .{});
    const file = try openAttributesWindows(dir, sub_path);
    defer file.close(io);
    try file.setPermissions(io, permissions);
}

/// `Dir.setTimestamps`, on Windows as well, where the standard library's
/// has no implementation in 0.17: there the times are written through a
/// handle opened for nothing else.
pub const SetTimestampsError = Io.Dir.SetTimestampsError || error{FileNotFound};

pub fn setTimestamps(io: Io, dir: Io.Dir, sub_path: []const u8, options: Io.File.SetTimestampsOptions) SetTimestampsError!void {
    if (builtin.target.os.tag != .windows) return dir.setTimestamps(io, sub_path, .{
        .access_timestamp = options.access_timestamp,
        .modify_timestamp = options.modify_timestamp,
    });
    const file = try openAttributesWindows(dir, sub_path);
    defer file.close(io);
    try file.setTimestamps(io, options);
}

/// Link two paths in a directory. Zig 0.17's threaded I/O has no Windows
/// implementation of `Dir.hardLink`, although the filesystem supports it.
pub const HardLinkError = Io.Dir.HardLinkError || Io.Dir.RealPathError || std.fmt.BufPrintError || Io.Threaded.Wtf8ToPrefixedFileWError || error{OperationUnsupported};

pub fn hardLink(io: Io, dir: Io.Dir, old_path: []const u8, new_path: []const u8) HardLinkError!void {
    if (builtin.target.os.tag != .windows) return dir.hardLink(old_path, dir, new_path, io, .{});
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    var old_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var new_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const old_absolute = if (std.Io.Dir.path.isAbsolute(old_path)) old_path else try std.mem.print(&old_buf, "{s}/{s}", .{ root, old_path });
    const new_absolute = if (std.Io.Dir.path.isAbsolute(new_path)) new_path else try std.mem.print(&new_buf, "{s}/{s}", .{ root, new_path });
    const old_w = try Io.Threaded.sliceToPrefixedFileW(null, old_absolute, .{});
    const new_w = try Io.Threaded.sliceToPrefixedFileW(null, new_absolute, .{});
    if (!CreateHardLinkW(new_w.span().ptr, old_w.span().ptr, null).toBool()) return error.OperationUnsupported;
}

extern "kernel32" fn CreateHardLinkW(new_path: [*:0]const u16, old_path: [*:0]const u16, security_attributes: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;

/// Whether `sub_path` in `dir` is the current user's: git's
/// `is_path_owned_by_current_user`. On POSIX its owner, not following a
/// symbolic link, is the effective user; on Windows its owner is the
/// user's SID, or the Administrators group when the user is one, and the
/// user's home (`home`, as git reads `HOME`) is always theirs. A path that
/// cannot be asked about is not owned: where the platform cannot say whose
/// a file is -- WASI, which has no users, or a POSIX build without libc
/// beyond Linux -- nothing is, and a caller that trusts its paths there
/// opens with `OpenOptions.ownership = .trust`.
pub fn ownedByCurrentUser(io: Io, dir: Io.Dir, sub_path: []const u8, home: ?[]const u8) bool {
    switch (builtin.target.os.tag) {
        .windows => return ownedWindows(io, dir, sub_path, home),
        .wasi => return false,
        else => {
            const found = switch (platstat.full(dir, sub_path)) {
                .found => |f| f,
                .absent, .unavailable => return false,
            };
            const euid: u32 = switch (builtin.target.os.tag) {
                .linux => std.os.linux.geteuid(),
                else => if (builtin.link_libc) std.c.geteuid() else return false,
            };
            return found.extra.uid == euid;
        },
    }
}

const se_file_object: c_int = 1;
const owner_security_information: u32 = 0x1;
const dacl_security_information: u32 = 0x4;
const token_query: u32 = 0x8;
const token_user: c_int = 1;
const token_linked_token: c_int = 19;
const win_builtin_administrators_sid: c_int = 26;

extern "advapi32" fn GetNamedSecurityInfoW(object_name: [*:0]const u16, object_type: c_int, info: u32, owner: ?*?*anyopaque, group: ?*?*anyopaque, dacl: ?*?*anyopaque, sacl: ?*?*anyopaque, descriptor: ?*?*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn OpenProcessToken(process: std.os.windows.HANDLE, access: u32, token: *std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
extern "advapi32" fn GetTokenInformation(token: std.os.windows.HANDLE, class: c_int, info: ?*anyopaque, length: u32, returned: *u32) callconv(.winapi) std.os.windows.BOOL;
extern "advapi32" fn IsValidSid(sid: *anyopaque) callconv(.winapi) std.os.windows.BOOL;
extern "advapi32" fn EqualSid(a: *anyopaque, b: *anyopaque) callconv(.winapi) std.os.windows.BOOL;
extern "advapi32" fn IsWellKnownSid(sid: *anyopaque, kind: c_int) callconv(.winapi) std.os.windows.BOOL;
extern "advapi32" fn CheckTokenMembership(token: ?std.os.windows.HANDLE, sid: *anyopaque, member: *std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn CloseHandle(handle: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;

fn ownedWindows(io: Io, dir: Io.Dir, sub_path: []const u8, home: ?[]const u8) bool {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = dir.realPath(io, &root_buf) catch return false;
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = if (std.mem.eql(u8, sub_path, "."))
        root_buf[0..root_len]
    else
        std.mem.print(&path_buf, "{s}\\{s}", .{ root_buf[0..root_len], sub_path }) catch return false;
    if (home) |h| if (std.ascii.eqlIgnoreCase(h, path)) return true;
    var wide_buf: [Io.Dir.max_path_bytes]u16 = undefined;
    const wide_len = std.unicode.wtf8ToWtf16Le(&wide_buf, path) catch return false;
    if (wide_len + 1 > wide_buf.len) return false;
    wide_buf[wide_len] = 0;
    var owner: ?*anyopaque = null;
    var descriptor: ?*anyopaque = null;
    if (GetNamedSecurityInfoW(wide_buf[0..wide_len :0].ptr, se_file_object, owner_security_information | dacl_security_information, &owner, null, null, null, &descriptor) != 0) return false;
    defer _ = LocalFree(descriptor);
    const sid = owner orelse return false;
    if (!IsValidSid(sid).toBool()) return false;
    var token: std.os.windows.HANDLE = undefined;
    if (!OpenProcessToken(GetCurrentProcess(), token_query, &token).toBool()) return false;
    defer _ = CloseHandle(token);
    var user_buf: [256]u8 align(@alignOf(usize)) = undefined;
    var size: u32 = 0;
    if (GetTokenInformation(token, token_user, &user_buf, user_buf.len, &size).toBool()) {
        // TOKEN_USER begins with the user's SID
        const user_sid: *anyopaque = @as(*const *anyopaque, @ptrCast(&user_buf)).*; // safe: TOKEN_USER's first field is a SID pointer, and the buffer is aligned for it
        if (IsValidSid(user_sid).toBool() and EqualSid(sid, user_sid).toBool()) return true;
    }
    if (IsWellKnownSid(sid, win_builtin_administrators_sid).toBool()) {
        var member: std.os.windows.BOOL = .FALSE;
        if (CheckTokenMembership(null, sid, &member).toBool() and member.toBool()) return true;
        var linked: std.os.windows.HANDLE = undefined;
        if (GetTokenInformation(token, token_linked_token, @ptrCast(&linked), @sizeOf(std.os.windows.HANDLE), &size).toBool()) { // safe: TOKEN_LINKED_TOKEN is one handle, which this receives
            defer _ = CloseHandle(linked);
            if (CheckTokenMembership(linked, sid, &member).toBool() and member.toBool()) return true;
        }
    }
    return false;
}

/// A handle to `sub_path`, a file or a directory, that may read and write
/// its attributes and times and do nothing else.
fn openAttributesWindows(dir: Io.Dir, sub_path: []const u8) (Io.Dir.PathNameError || Io.Cancelable || error{ FileNotFound, AccessDenied, Unexpected })!Io.File {
    const windows = std.os.windows;
    const path_w = try Io.Threaded.sliceToPrefixedFileW(dir.handle, sub_path, .{});
    const span = path_w.span();
    var object_name = windows.UNICODE_STRING.init(span);
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var handle: windows.HANDLE = undefined;
    switch (windows.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true, .WRITE_ATTRIBUTES = true } },
        },
        &.{
            .RootDirectory = if (Io.Dir.path.isAbsoluteWindowsWtf16(span)) null else dir.handle,
            .ObjectName = &object_name,
        },
        &iosb,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{ .IO = .SYNCHRONOUS_NONALERT },
        null,
        0,
    )) {
        .SUCCESS => return .{ .handle = handle, .flags = .{ .nonblocking = false } },
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .ACCESS_DENIED, .SHARING_VIOLATION => return error.AccessDenied,
        else => |status| return windows.unexpectedStatus(status),
    }
}

/// Remove a file, taking a read-only attribute off first where the
/// platform will not remove a read-only file, as git for Windows does.
pub fn deleteFile(io: Io, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
    dir.deleteFile(io, sub_path) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => {
            if (!clearReadOnly(io, dir, sub_path)) return err;
            return dir.deleteFile(io, sub_path);
        },
        else => |e| return e,
    };
}

/// What can be found out about a lock this process did not take.
pub const StaleReport = struct {
    /// Whether `<path>.lock` is there at all.
    held: bool,
    /// The process id the lock names, when it names one.
    pid: ?u32,
    /// Whether that process still exists. `null` when there was no pid file
    /// or the platform cannot be asked.
    ///
    /// Process ids are reused, so `true` does not prove the lock is live and
    /// `false` does not license breaking it. The lock is never removed here.
    holder_alive: ?bool,
};

/// What is known about the lock on `sub_path`.
///
/// A caller shows this to a person. Nothing in this package ever removes a
/// lock it did not take, whatever the report says.
pub fn staleReport(io: Io, dir: Io.Dir, sub_path: []const u8) StaleReport {
    var name_buf: [512]u8 = undefined;
    const lock_name = std.mem.print(&name_buf, "{s}.lock", .{sub_path}) catch return .{ .held = false, .pid = null, .holder_alive = null };
    dir.access(io, lock_name, .{}) catch return .{ .held = false, .pid = null, .holder_alive = null };

    // The lock's own first bytes while it is held: `pid <n>`.
    var contents: [64]u8 = undefined;
    // Holds the longest line `LockFile.open` writes.
    comptime assert(contents.len >= "pid 4294967295\n".len);
    const text = dir.readFile(io, lock_name, &contents) catch
        return .{ .held = true, .pid = null, .holder_alive = null };
    const line = text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
    if (!std.mem.startsWith(u8, line, "pid ")) return .{ .held = true, .pid = null, .holder_alive = null };
    const pid = std.fmt.parseInt(u32, line[4..], 10) catch
        return .{ .held = true, .pid = null, .holder_alive = null };
    return .{ .held = true, .pid = pid, .holder_alive = processAlive(pid) };
}

fn currentPid() u32 {
    return switch (builtin.target.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .wasi => 0,
        else => @intCast(std.posix.system.getpid()),
    };
}

test "currentPid uses the host process API" {
    const expected: u32 = switch (builtin.target.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .wasi => 0,
        else => @intCast(std.posix.system.getpid()),
    };
    try std.testing.expectEqual(expected, currentPid());
}

/// Whether a process has the id `pid`, as conduit asks the system; a
/// number the platform's ids cannot hold names no process at all: the file
/// was written by something else.
fn processAlive(pid: u32) ?bool {
    const id = std.math.cast(conduit.Child.Id, pid) orelse return false;
    return conduit.processExists(id);
}

/// Whether `<sub_path>.lock` exists in `dir`.
pub fn lockHeld(io: Io, dir: Io.Dir, sub_path: []const u8) bool {
    return staleReport(io, dir, sub_path).held;
}

/// Errors from replacing a file whole.
pub const AtomicWriteError = Io.File.OpenError || Io.Writer.Error ||
    SyncError || Io.Dir.RenameError || Io.Dir.DeleteFileError;

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
    sync: Sync,
) Self.AtomicWriteError!void {
    var name_buf: [128]u8 = undefined;
    const temp = tempName(io, &name_buf, prefix);
    var file = try dir.createFile(io, temp, .{ .exclusive = true });
    errdefer {
        file.close(io);
        dir.deleteFile(io, temp) catch {};
    }
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &write_buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
    switch (sync) {
        .none => {},
        .batch => try syncFileLevel(io, file, .ordered),
        .per_file => try syncFileLevel(io, file, .data),
    }
    file.close(io);
    renameWithRetry(io, dir, temp, sub_path) catch |err| {
        // ziglint-ignore: Z026 the rename's error is the one to report; a temporary left behind is what `git gc` prunes
        dir.deleteFile(io, temp) catch {};
        return err;
    };
}

/// A name no other process will pick, written into `buf`.
///
/// Randomness comes from the operating system, not from a clock: nothing in
/// this package reads one.
pub fn tempName(io: Io, buf: []u8, prefix: []const u8) []const u8 {
    var raw: [12]u8 = undefined;
    var hex: [2 * raw.len]u8 = undefined;
    assert(buf.len >= prefix.len + hex.len);
    io.random(&raw);
    // unreachable: twelve bytes are twenty-four hex digits
    _ = std.mem.print(&hex, "{x}", .{&raw}) catch unreachable;
    // unreachable: the caller's buffer holds the prefix and the digits, asserted above
    return std.mem.print(buf, "{s}{s}", .{ prefix, hex }) catch unreachable;
}

/// Errors from reading a file whose length is already known.
pub const ReadSizedError = Io.File.OpenError || Io.File.ReadPositionalError ||
    Io.Dir.ReadFileAllocError || Allocator.Error;

/// Read a file a stat has already measured.
///
/// The walk that found the file already knows how long it is, so the `fstat`
/// a general read does to find that out is one syscall per file that a cold
/// pass over a working tree pays for nothing. The size is a hint and not a
/// promise: a file that shrank gives back what is there, and a file that grew
/// is read again the general way.
///
/// The bytes are the caller's.
pub fn readFileSized(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    size: u64,
    max_bytes: usize,
) Self.ReadSizedError![]u8 {
    if (size > max_bytes) return error.StreamTooLong;
    const file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    const buf = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n < buf.len) return gpa.realloc(buf, n);
    // The file is at least as long as the stat said. One byte past the end
    // says whether it is longer, which is the only case this cannot finish.
    var probe: [1]u8 = undefined;
    if (try file.readPositional(io, &.{&probe}, size) == 0) return buf;
    gpa.free(buf);
    return dir.readFileAlloc(io, sub_path, gpa, .limited(max_bytes));
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

test "the filesystem's timestamp resolution is measured, not assumed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const measured = probeTimestampResolution(io, tmp.dir);
    try std.testing.expect(measured.measured);
    // A round unit, no finer than a nanosecond and no coarser than a second.
    try std.testing.expect(measured.ns >= 1);
    try std.testing.expect(measured.ns <= std.time.ns_per_s);
    var unit: u64 = 1;
    while (unit < measured.ns) unit *= 10;
    try std.testing.expectEqual(unit, measured.ns);
    try std.testing.expectEqual(measured.ns < std.time.ns_per_s, measured.hasSubsecond());

    // The probe leaves nothing behind.
    var dir = try tmp.parent_dir.openDir(io, &tmp.sub_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, "relic_tres_"));
    }
}

test "a stat shortcut believes exactly as many nanoseconds as were measured" {
    const a: Stat = .{ .mtime_sec = 1000, .mtime_nsec = 1_000_000, .size = 7 };
    const b: Stat = .{ .mtime_sec = 1000, .mtime_nsec = 1_000_500, .size = 7 };
    const c: Stat = .{ .mtime_sec = 1000, .mtime_nsec = 2_500_000, .size = 7 };

    // Every nanosecond kept: half a microsecond apart is a different file.
    try std.testing.expect(!a.matches(b, .full, .nanosecond));
    // Milliseconds kept: half a microsecond is below what the filesystem
    // records, a millisecond and a half is not.
    const millisecond: Resolution = .{ .ns = 1_000_000, .measured = true };
    try std.testing.expect(a.matches(b, .full, millisecond));
    try std.testing.expect(!a.matches(c, .full, millisecond));
    // Seconds kept: the nanosecond field says nothing at all.
    try std.testing.expect(a.matches(b, .full, .second));
    try std.testing.expect(a.matches(c, .full, .second));
    // And the size still decides, whatever the resolution.
    const bigger: Stat = .{ .mtime_sec = 1000, .mtime_nsec = 1_000_000, .size = 8 };
    try std.testing.expect(!a.matches(bigger, .full, .second));
}

test "one stat and two stats describe a path the same way" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.writeFile(io, .{ .sub_path = "plain", .data = "some bytes\n" });
    try dir.createDir(io, "sub", .default_dir);
    var has_link = true;
    dir.symLink(io, "plain", "link", .{}) catch {
        has_link = false;
    };

    const names: []const []const u8 = if (has_link)
        &.{ "plain", "sub", "link" }
    else
        &.{ "plain", "sub" };
    for (names) |name| {
        const one = (try statAt(io, dir, name)).?;
        // The two-call path, which is what a platform without a full stat
        // takes. Both must agree, or a walk would see a different working
        // tree depending on the platform.
        const s = try dir.statFile(io, name, .{ .follow_symlinks = false });
        const two: Entry = .{
            .stat = .fromIo(s, platstat.statAt(dir, name)),
            .kind = s.kind,
            .executable = isExecutable(s.permissions),
        };
        try std.testing.expectEqual(two.kind, one.kind);
        try std.testing.expectEqual(two.executable, one.executable);
        try std.testing.expectEqual(two.stat.size, one.stat.size);
        try std.testing.expectEqual(two.stat.ino, one.stat.ino);
        try std.testing.expectEqual(two.stat.dev, one.stat.dev);
        try std.testing.expectEqual(two.stat.uid, one.stat.uid);
        try std.testing.expectEqual(two.stat.gid, one.stat.gid);
        try std.testing.expectEqual(two.stat.mtime_sec, one.stat.mtime_sec);
        try std.testing.expectEqual(two.stat.mtime_nsec, one.stat.mtime_nsec);
    }
    try std.testing.expect((try statAt(io, dir, "not-there")) == null);
}

test "a sized read gives the whole file whatever the size said" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.writeFile(io, .{ .sub_path = "f", .data = "twelve bytes" });

    // The size a stat reported.
    const exact = try readFileSized(gpa, io, dir, "f", 12, 1 << 20);
    defer gpa.free(exact);
    try std.testing.expectEqualStrings("twelve bytes", exact);

    // A file that grew after the stat: the read is started again rather than
    // cut short at the length the stat gave.
    const grown = try readFileSized(gpa, io, dir, "f", 4, 1 << 20);
    defer gpa.free(grown);
    try std.testing.expectEqualStrings("twelve bytes", grown);

    // A file that shrank: what is there is what comes back.
    const shrunk = try readFileSized(gpa, io, dir, "f", 64, 1 << 20);
    defer gpa.free(shrunk);
    try std.testing.expectEqualStrings("twelve bytes", shrunk);

    const empty = try readFileSized(gpa, io, dir, "f", 0, 1 << 20);
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("twelve bytes", empty);

    try std.testing.expectError(error.StreamTooLong, readFileSized(gpa, io, dir, "f", 12, 4));
}

test "a lock is refused, not broken, and says who holds it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.writeFile(io, .{ .sub_path = "thing", .data = "old\n" });

    var buf: [64]u8 = undefined;
    var lock = try LockFile.open(gpa, io, dir, "thing", &buf, .{});
    defer lock.deinit(io);

    var buf2: [64]u8 = undefined;
    try std.testing.expectError(
        error.LockHeld,
        LockFile.open(gpa, io, dir, "thing", &buf2, .{}),
    );
    const report = staleReport(io, dir, "thing");
    try std.testing.expect(report.held);
    if (builtin.target.os.tag != .wasi) try std.testing.expectEqual(@as(?u32, currentPid()), report.pid);
    if (report.holder_alive) |alive| try std.testing.expect(alive);

    try lock.writer().writeAll("new\n");
    try lock.commit(io);

    var read_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("new\n", try dir.readFile(io, "thing", &read_buf));
    try std.testing.expect(!lockHeld(io, dir, "thing"));
}

test "a lock names its holder in its own bytes, and no file but the lock is made" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = tmp.dir;
    // Contents shorter than the name under them, and none at all.
    for ([_][]const u8{ "x", "" }) |contents| {
        var buf: [64]u8 = undefined;
        var lock = try LockFile.open(gpa, io, dir, "thing", &buf, .{});
        defer lock.deinit(io);
        var count: usize = 0;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, "thing")) continue;
            try std.testing.expectEqualStrings("thing.lock", entry.name);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
        try lock.writer().writeAll(contents);
        try lock.commit(io);
        var read_buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings(contents, try dir.readFile(io, "thing", &read_buf));
    }
}

test "a lock syncs the target's directory after rename only when asked" {
    const seam = @import("airlock.testing");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "nested", .default_dir);
    for ([_][]const u8{ "thing", "nested/thing" }) |target| {
        for ([_]Sync{ .none, .batch, .per_file }) |policy| {
            for ([_]bool{ false, true }) |sync_directory| {
                const h = try seam.Seam.create(std.testing.allocator, std.testing.io, .{});
                defer h.destroy();
                const io = h.io();
                var buf: [64]u8 = undefined;
                var lock = try LockFile.open(std.testing.allocator, io, tmp.dir, target, &buf, .{
                    .sync = policy,
                    .sync_directory = sync_directory,
                });
                defer lock.deinit(io);
                try lock.writer().writeAll("new\n");
                try lock.commit(io);
                try std.testing.expectEqual(@as(u32, @intFromBool(sync_directory)), h.count(.sync_dir));
                const file_call: seam.Call = if (policy == .batch and builtin.target.os.tag.isDarwin()) .sync_barrier else seam.data_sync;
                try std.testing.expectEqual(@as(u32, @intFromBool(policy != .none)), h.count(file_call));
                try std.testing.expectEqual(@as(u32, @intFromBool(policy != .none) + @as(u32, @intFromBool(sync_directory))), h.syncs());
                var read_buf: [16]u8 = undefined;
                try std.testing.expectEqualStrings("new\n", try tmp.dir.readFile(io, target, &read_buf));
                try std.testing.expect(!lockHeld(io, tmp.dir, target));
            }
        }
    }
}

test "phase2 airlock file failure prevents lock publication and directory failure is explicit" {
    const seam = @import("airlock.testing");
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |directory_failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "thing", .data = "old\n" });
        const h = try seam.Seam.create(gpa, std.testing.io, .{
            .plan = &.{seam.fail(if (directory_failure) .sync_dir else seam.data_sync, 1, seam.io_error)},
        });
        defer h.destroy();
        const io = h.io();
        {
            var buffer: [64]u8 = undefined;
            var lock = try LockFile.open(gpa, io, tmp.dir, "thing", &buffer, .{ .sync = .per_file, .sync_directory = true });
            defer lock.deinit(io);
            try lock.writer().writeAll("new\n");
            try std.testing.expectError(error.InputOutput, lock.commit(io));
            var read_buf: [16]u8 = undefined;
            try std.testing.expectEqualStrings(if (directory_failure) "new\n" else "old\n", try tmp.dir.readFile(io, "thing", &read_buf));
            try std.testing.expectEqual(!directory_failure, lockHeld(io, tmp.dir, "thing"));
        }
        try std.testing.expect(!lockHeld(io, tmp.dir, "thing"));
        try std.testing.expectEqual(@as(u32, 1), h.count(if (directory_failure) .sync_dir else seam.data_sync));
    }
}

test "phase2 airlock refused durability never publishes weaker file data" {
    const seam = @import("airlock.testing");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "thing", .data = "old\n" });
    const h = try seam.Seam.create(std.testing.allocator, std.testing.io, .{
        .plan = &.{ seam.always(seam.data_sync, seam.refused), seam.always(.sync_full, seam.refused), seam.always(.sync_plain, seam.refused) },
    });
    defer h.destroy();
    const io = h.io();
    var buffer: [64]u8 = undefined;
    var lock = try LockFile.open(std.testing.allocator, io, tmp.dir, "thing", &buffer, .{ .sync = .per_file });
    defer lock.deinit(io);
    try lock.writer().writeAll("new\n");
    try std.testing.expectError(error.LevelUnavailable, lock.commit(io));
    var read_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("old\n", try tmp.dir.readFile(io, "thing", &read_buf));
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
        var lock = try LockFile.open(gpa, io, dir, "thing", &buf, .{});
        defer lock.deinit(io);
        try lock.writer().writeAll("never\n");
    }
    var read_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("old\n", try dir.readFile(io, "thing", &read_buf));
    try std.testing.expect(!lockHeld(io, dir, "thing"));
}

test "a failed lock rename removes the closed lock file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.createDir(io, "thing", .default_dir);

    var buf: [64]u8 = undefined;
    var lock = try LockFile.open(gpa, io, dir, "thing", &buf, .{});
    try lock.writer().writeAll("cannot replace a directory\n");
    try std.testing.expectError(error.IsDir, lock.commit(io));
    lock.deinit(io);

    try std.testing.expectError(error.FileNotFound, dir.access(io, "thing.lock", .{}));
}

test "an allocation failure abandons no lock" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var buf: [64]u8 = undefined;

    try std.testing.expectError(
        error.OutOfMemory,
        LockFile.open(failing.allocator(), io, tmp.dir, "thing", &buf, .{}),
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "thing.lock", .{}));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "waiting for a lock gives up with the same named error" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    var buf: [64]u8 = undefined;
    var lock = try LockFile.open(gpa, io, dir, "thing", &buf, .{});
    defer lock.deinit(io);

    var buf2: [64]u8 = undefined;
    try std.testing.expectError(
        error.LockHeld,
        LockFile.open(gpa, io, dir, "thing", &buf2, .{ .on_contention = .{ .wait_ms = 5 } }),
    );
}

test "the batch barrier costs one sync and leaves nothing behind" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try syncBarrier(io, tmp.dir);
    var it = tmp.dir.iterate();
    try std.testing.expect((try it.next(io)) == null);
}

test "a batch barrier reports that its file could not be created" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "occupied", .data = "keep\n" });

    try std.testing.expectError(error.PathAlreadyExists, syncBarrierNamed(io, tmp.dir, "occupied"));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("keep\n", try tmp.dir.readFile(io, "occupied", &buf));
}

test "a read-only file is replaced and removed, as a lockable one nobody holds must be" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "locked.bin", .data = "old" });
    const st = try tmp.dir.statFile(io, "locked.bin", .{});
    try setFilePermissions(io, tmp.dir, "locked.bin", withReadOnly(st.permissions, true));
    try tmp.dir.writeFile(io, .{ .sub_path = "new.tmp", .data = "new" });
    try renameWithRetry(io, tmp.dir, "new.tmp", "locked.bin");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("new", try tmp.dir.readFile(io, "locked.bin", &buf));
    const again = try tmp.dir.statFile(io, "locked.bin", .{});
    try setFilePermissions(io, tmp.dir, "locked.bin", withReadOnly(again.permissions, true));
    try deleteFile(io, tmp.dir, "locked.bin");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "locked.bin", .{}));
}
