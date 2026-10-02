//! The ref backend, hash and cache live and change together under Store.
//! This module is package plumbing, reached by no public name.
const std = @import("std");
const hash = @import("hash.zig");
const refs = @import("ref_types.zig");
const stack = @import("stack_cache.zig");

pub const State = opaque {};

pub const Data = struct {
    gpa: std.mem.Allocator,
    git_dir: std.Io.Dir,
    common_dir: std.Io.Dir,
    kind: hash.Kind,
    format: refs.Format,
    options: @import("stack_types.zig").Options,
    cache: ?*stack.Cache,
};

pub fn get(state: *State) *Data {
    return @ptrCast(@alignCast(state)); // safe: create allocates every State as an aligned Data.
}

pub fn create(gpa: std.mem.Allocator, kind: hash.Kind, format: refs.Format, options: @import("stack_types.zig").Options, git_dir: std.Io.Dir, common_dir: std.Io.Dir) std.mem.Allocator.Error!*State {
    const data = try gpa.create(Data);
    errdefer gpa.destroy(data);
    const cache = if (format == .reftable) blk: {
        const c = try gpa.create(stack.Cache);
        c.* = .init(gpa);
        break :blk c;
    } else null;
    data.* = .{ .gpa = gpa, .git_dir = git_dir, .common_dir = common_dir, .kind = kind, .format = format, .options = options, .cache = cache };
    return @ptrCast(data); // safe: the opaque owner retains the allocated Data pointer.
}

pub fn destroy(gpa: std.mem.Allocator, state: *State) void {
    const data = get(state);
    if (data.cache) |c| {
        c.deinit();
        gpa.destroy(c);
    }
    gpa.destroy(data);
}
