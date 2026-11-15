//! The ref backend, hash and cache live and change together under Store.
//! This module is package plumbing, reached by no public name.
const fs = @import("../fs/fs.zig");
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const hash = @import("../hash/hash.zig");
const refs = @import("value.zig");
const stack = @import("reftable/stack/cache.zig");
const packed_cache = @import("packed.zig");
const policy = @import("reftable/stack/policy.zig");

/// The store's format, directories and caches: `Store.state`, private to it.
pub const State = struct {
    gpa: std.mem.Allocator,
    /// Lent by the store's caller, which closes them after the store.
    git_dir: aegis.own.Unowned(Io.Dir),
    common_dir: aegis.own.Unowned(Io.Dir),
    kind: hash.Kind,
    format: refs.Format,
    options: policy.Options,
    cache: ?*stack.Cache,
    /// `packed-refs` as last read, for the files format.
    packed_refs: ?*packed_cache.Cache,
    /// What `core.sharedRepository` asks of the permissions of what is
    /// written.
    shared: fs.Shared = .umask,
    /// `core.fsync`: refs, `packed-refs` and logs are references.
    fsync: fs.Fsync = .default,
    /// How the store's locks wait and say who holds them.
    locks: Locks = .{},
    /// `core.precomposeUnicode` on macOS: loose ref names read composed.
    precompose: bool = false,
    /// `core.preferSymlinkRefs`: a symbolic ref written as a symbolic link.
    symlink_refs: bool = false,
};

/// A lock's wait as git's configuration counts it.
const Milliseconds = aegis.units.Duration(.millisecond, u32);

/// How a store's locks behave, as the configuration says: how long a
/// writer waits for a held one -- `core.packedRefsTimeout` for
/// `packed-refs`, a second unless set; `core.filesRefLockTimeout` for a
/// loose ref, a tenth of one -- and whether each names its holder in a
/// `~pid.lock` beside it, `core.lockfilePid`.
pub const Locks = struct {
    packed_refs: fs.OnContention = .{ .wait = Milliseconds.fromRaw(1000).toIoDuration() },
    loose: fs.OnContention = .{ .wait = Milliseconds.fromRaw(100).toIoDuration() },
    pid_file: bool = false,
};

pub fn create(gpa: std.mem.Allocator, kind: hash.Kind, format: refs.Format, options: policy.Options, git_dir: Io.Dir, common_dir: Io.Dir) std.mem.Allocator.Error!*State {
    const data = try gpa.create(State);
    errdefer gpa.destroy(data);
    const cache = if (format == .reftable) blk: {
        const c = try gpa.create(stack.Cache);
        c.* = .init(gpa);
        break :blk c;
    } else null;
    errdefer if (cache) |c| gpa.destroy(c);
    const packed_refs = if (format == .files) blk: {
        const c = try gpa.create(packed_cache.Cache);
        c.* = .init(gpa);
        break :blk c;
    } else null;
    data.* = .{ .gpa = gpa, .git_dir = .of(git_dir), .common_dir = .of(common_dir), .kind = kind, .format = format, .options = options, .cache = cache, .packed_refs = packed_refs };
    return data;
}

pub fn destroy(gpa: std.mem.Allocator, state: *State) void {
    const data = state;
    if (data.cache) |c| {
        c.deinit();
        gpa.destroy(c);
    }
    if (data.packed_refs) |c| {
        c.deinit();
        gpa.destroy(c);
    }
    gpa.destroy(data);
}

/// All errors reported by this namespace.
pub const Error = std.mem.Allocator.Error;
