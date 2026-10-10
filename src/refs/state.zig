//! The ref backend, hash and cache live and change together under Store.
//! This module is package plumbing, reached by no public name.
const fs = @import("../fs/fs.zig");
const std = @import("std");
const hash = @import("../hash/hash.zig");
const refs = @import("value.zig");
const stack = @import("reftablestack/cache.zig");
const packed_cache = @import("packed.zig");
const policy = @import("reftablestack/policy.zig");

pub const State = opaque {};

pub const Data = struct {
    gpa: std.mem.Allocator,
    git_dir: std.Io.Dir,
    common_dir: std.Io.Dir,
    kind: hash.Kind,
    format: refs.Format,
    options: policy.Options,
    cache: ?*stack.Cache,
    /// `packed-refs` as last read, for the files format.
    packed_refs: ?*packed_cache.Cache,
    /// What `core.sharedRepository` asks of the permissions of what is
    /// written.
    shared: fs.Shared = .umask,
    /// `core.packedRefsTimeout`: how long a writer waits for
    /// `packed-refs.lock`. git waits a second unless told otherwise.
    packed_lock: fs.OnContention = .{ .wait_ms = 1000 },
};

pub fn get(state: *State) *Data {
    return @ptrCast(@alignCast(state)); // safe: create allocates every State as an aligned Data.
}

pub fn create(gpa: std.mem.Allocator, kind: hash.Kind, format: refs.Format, options: policy.Options, git_dir: std.Io.Dir, common_dir: std.Io.Dir) std.mem.Allocator.Error!*State {
    const data = try gpa.create(Data);
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
    data.* = .{ .gpa = gpa, .git_dir = git_dir, .common_dir = common_dir, .kind = kind, .format = format, .options = options, .cache = cache, .packed_refs = packed_refs };
    return @ptrCast(data); // safe: the opaque owner retains the allocated Data pointer.
}

pub fn destroy(gpa: std.mem.Allocator, state: *State) void {
    const data = get(state);
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
