//! The file protocol git uses, and nothing else.
//!
//! Every replacement goes through `LockFile` or `atomicWrite`:
//! `O_CREAT|O_EXCL` on a neighbouring name, write, make durable as the policy
//! asks, rename. No advisory lock is taken anywhere, because git takes none
//! and a lock that is not the lock git holds is a lock that does not stop it.
//!
//! A lock another process holds is reported, never broken — with the holder's
//! process id where it can be found, which is what git itself now writes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const safepath = @import("safepath.zig");
const platstat = @import("platstat.zig");

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

/// On macOS `fsync(2)` pushes bytes to the device and returns; only
/// `fcntl(F_FULLFSYNC)` flushes the drive's own write cache, and it costs
/// about thirty times as much per call. `std.Io.File.sync` is plain `fsync`,
/// which is exactly what git's own macOS default (`fsyncMethod =
/// writeout-only`) asks for — so this package is right by inheritance rather
/// than by choice. Do not "fix" it into `F_FULLFSYNC` per file: that makes
/// every write thirty times slower for a guarantee the batch barrier already
/// gives once per batch.
pub const macos_fsync_is_writeout_only = builtin.os.tag == .macos;

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
        if (builtin.os.tag == .windows) file.sync(io) catch {};
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
pub fn statAt(io: Io, dir: Io.Dir, sub_path: []const u8) StatError!?Entry {
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

/// The permissions a blob's mode asks for: 0o777 when executable, 0o666
/// otherwise, before the process umask — which is what git creates files
/// with. Where the platform has no executable bit this is the default and
/// the index's mode is what carries the truth.
pub fn permissionsFor(executable: bool) Io.File.Permissions {
    if (!Io.File.Permissions.has_executable_bit) return .default_file;
    return @enumFromInt(@as(std.posix.mode_t, if (executable) 0o777 else 0o666));
}

/// Whether directory entries are made durable after a rename.
///
/// git does not do this: its lock file code calls `fsync` nowhere, and every
/// `fsync` in its tree is on a file descriptor. The choice is stated here
/// rather than assumed: off by default, because the guarantee it adds is one
/// git itself does not make, and on by request for a caller who wants it. It
/// is a no-op on Windows, which has no equivalent.
pub const sync_directories_default = false;

/// `fsync` on a directory, so a name that was created or renamed is durable.
///
/// Windows has no equivalent and this is a no-op there; the guarantee is the
/// operating system's.
pub fn syncDir(io: Io, dir: Io.Dir) Io.File.SyncError!void {
    if (builtin.os.tag == .windows) return;
    const as_file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    as_file.sync(io) catch |err| switch (err) {
        // A filesystem that refuses to sync a directory handle is not one
        // this can do anything about, and the write itself already reached
        // the operating system.
        error.AccessDenied, error.Unexpected => return,
        else => |e| return e,
    };
}

/// Put one durability barrier at the end of a batch of writes.
///
/// git's own method: create a throwaway file in the same directory, sync it,
/// and remove it. Everything flushed into the same writeback cache before it
/// is durable once it returns, at the cost of one sync instead of one per
/// file. On macOS that is the difference between milliseconds and seconds.
pub fn syncBarrier(io: Io, dir: Io.Dir) (Io.File.OpenError || Io.File.SyncError)!void {
    var name_buf: [64]u8 = undefined;
    const name = tempName(io, &name_buf, "relic_fsync_");
    return syncBarrierNamed(io, dir, name);
}

fn syncBarrierNamed(io: Io, dir: Io.Dir, name: []const u8) (Io.File.OpenError || Io.File.SyncError)!void {
    const file = try dir.createFile(io, name, .{ .exclusive = true });
    defer {
        file.close(io);
        dir.deleteFile(io, name) catch {};
    }
    try file.sync(io);
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
pub const CommitError = Io.Writer.Error || Io.File.SyncError || Io.Dir.RenameError;

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
    /// `<target>~pid.lock`, owned by this lock, when one was written.
    pid_name: ?[]u8,
    gpa: Allocator,
    file: Io.File,
    file_writer: Io.File.Writer,
    sync: Sync,
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
        /// Whether to write `<target>~pid.lock` naming this process, so a
        /// later writer that meets the lock can say who holds it. The tilde
        /// is git's choice: it is forbidden in a ref name and legal in a
        /// Windows file name, so it cannot collide with anything.
        write_pid: bool = true,
        /// Whether to make the directory entry durable after the rename.
        sync_directory: bool = sync_directories_default,
    };

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
    ) (LockError || Allocator.Error)!LockFile {
        const lock_name = try std.fmt.allocPrint(gpa, "{s}.lock", .{sub_path});
        errdefer gpa.free(lock_name);

        const file = try createExclusive(io, dir, lock_name, options.on_contention);
        errdefer {
            file.close(io);
            dir.deleteFile(io, lock_name) catch {};
        }

        var pid_name: ?[]u8 = null;
        if (options.write_pid) {
            const name = try std.fmt.allocPrint(gpa, "{s}~pid.lock", .{sub_path});
            if (dir.createFile(io, name, .{ .exclusive = true })) |pid_file| {
                defer pid_file.close(io);
                var text: [32]u8 = undefined;
                const line = std.fmt.bufPrint(&text, "pid {d}\n", .{currentPid()}) catch unreachable;
                pid_file.writeStreamingAll(io, line) catch {};
                pid_name = name;
            } else |_| {
                gpa.free(name);
            }
        }

        return .{
            .dir = dir,
            .target = sub_path,
            .lock_name = lock_name,
            .pid_name = pid_name,
            .gpa = gpa,
            .file = file,
            .file_writer = file.writer(io, buffer),
            .sync = options.sync,
        };
    }

    /// The writer the new contents go through.
    pub fn writer(lock: *LockFile) *Io.Writer {
        return &lock.file_writer.interface;
    }

    /// Flush, make durable, close and rename over the target. After this the
    /// lock is gone and the new bytes are the file.
    pub fn commit(lock: *LockFile, io: Io) CommitError!void {
        std.debug.assert(!lock.finished);
        try lock.file_writer.interface.flush();
        switch (lock.sync) {
            .none => {},
            // Both arms sync the lock's own descriptor before the rename,
            // which is the step that prevents every corruption the field
            // reports: an empty ref, a truncated index, a zero-length loose
            // object. A batch differs from a per-file sync in what happens
            // at the end of the batch, not here.
            .batch, .per_file => try lock.file.sync(io),
        }
        lock.file.close(io);
        lock.finished = true;
        renameWithRetry(io, lock.dir, lock.lock_name, lock.target) catch |err| {
            lock.dir.deleteFile(io, lock.lock_name) catch {};
            lock.removePid(io);
            return err;
        };
        lock.removePid(io);
    }

    /// Give the lock up, leaving the target as it was. Safe to call after
    /// `commit`, which is what makes `defer lock.deinit(io)` the right shape.
    pub fn deinit(lock: *LockFile, io: Io) void {
        if (!lock.finished) {
            lock.file.close(io);
            lock.dir.deleteFile(io, lock.lock_name) catch {};
            lock.finished = true;
        }
        lock.removePid(io);
        lock.gpa.free(lock.lock_name);
        lock.* = undefined;
    }

    fn removePid(lock: *LockFile, io: Io) void {
        if (lock.pid_name) |name| {
            lock.dir.deleteFile(io, name) catch {};
            lock.gpa.free(name);
            lock.pid_name = null;
        }
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
            error.AccessDenied, error.PermissionDenied => if (builtin.os.tag != .windows) return err,
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
    if (builtin.os.tag != .windows) {
        return dir.rename(old_name, dir, new_name, io);
    }
    var attempts: u8 = 0;
    while (true) {
        if (dir.rename(old_name, dir, new_name, io)) {
            return;
        } else |err| switch (err) {
            error.AccessDenied, error.PermissionDenied, error.FileBusy => {
                attempts += 1;
                if (attempts >= 10) return err;
                Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }, io) catch return err;
            },
            else => return err,
        }
    }
}

/// What can be found out about a lock this process did not take.
pub const StaleReport = struct {
    /// Whether `<path>.lock` is there at all.
    held: bool,
    /// The process id in `<path>~pid.lock`, when one is there.
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
    const lock_name = std.fmt.bufPrint(&name_buf, "{s}.lock", .{sub_path}) catch return .{ .held = false, .pid = null, .holder_alive = null };
    dir.access(io, lock_name, .{}) catch return .{ .held = false, .pid = null, .holder_alive = null };

    var pid_buf: [512]u8 = undefined;
    const pid_name = std.fmt.bufPrint(&pid_buf, "{s}~pid.lock", .{sub_path}) catch
        return .{ .held = true, .pid = null, .holder_alive = null };
    var contents: [64]u8 = undefined;
    const text = dir.readFile(io, pid_name, &contents) catch
        return .{ .held = true, .pid = null, .holder_alive = null };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "pid ")) return .{ .held = true, .pid = null, .holder_alive = null };
    const pid = std.fmt.parseInt(u32, trimmed[4..], 10) catch
        return .{ .held = true, .pid = null, .holder_alive = null };
    return .{ .held = true, .pid = pid, .holder_alive = processAlive(pid) };
}

fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .wasi => 0,
        else => @intCast(std.posix.system.getpid()),
    };
}

test "currentPid uses the host process API" {
    const expected: u32 = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .wasi => 0,
        else => @intCast(std.posix.system.getpid()),
    };
    try std.testing.expectEqual(expected, currentPid());
}

fn processAlive(pid: u32) ?bool {
    switch (builtin.os.tag) {
        .windows, .wasi => return null,
        else => {
            if (!builtin.link_libc and builtin.os.tag != .linux) return null;
            // A pid that does not fit the platform's own type names no
            // process at all; the file was written by something else.
            const narrowed = std.math.cast(std.posix.pid_t, pid) orelse return false;
            const rc = if (builtin.os.tag == .linux)
                std.os.linux.kill(narrowed, @enumFromInt(0))
            else
                @as(usize, @bitCast(@as(isize, std.c.kill(narrowed, @enumFromInt(0)))));
            const e = std.posix.errno(rc);
            return switch (e) {
                .SUCCESS => true,
                // The process exists and is someone else's.
                .PERM => true,
                .SRCH => false,
                else => null,
            };
        },
    }
}

/// Whether `<sub_path>.lock` exists in `dir`.
pub fn lockHeld(io: Io, dir: Io.Dir, sub_path: []const u8) bool {
    return staleReport(io, dir, sub_path).held;
}

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
    sync: Sync,
) AtomicWriteError!void {
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
        .batch, .per_file => try file.sync(io),
    }
    file.close(io);
    renameWithRetry(io, dir, temp, sub_path) catch |err| {
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
    io.random(&raw);
    var hex: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&raw}) catch unreachable;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, hex }) catch unreachable;
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
) ReadSizedError![]u8 {
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
    if (report.pid) |pid| {
        try std.testing.expect(pid != 0);
        if (report.holder_alive) |alive| try std.testing.expect(alive);
    }

    try lock.writer().writeAll("new\n");
    try lock.commit(io);

    var read_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("new\n", try dir.readFile(io, "thing", &read_buf));
    try std.testing.expect(!lockHeld(io, dir, "thing"));
    // The pid file goes with the lock.
    try std.testing.expectError(error.FileNotFound, dir.access(io, "thing~pid.lock", .{}));
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
    try std.testing.expectError(error.FileNotFound, dir.access(io, "thing~pid.lock", .{}));
}

test "PID-name allocation failure abandons no lock" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
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
