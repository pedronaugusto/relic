//! Count submissions through the caller's Io, regardless of where the
//! executor runs them. Tests use one wrapper at a time, and await every
//! submitted task before wrapping another executor or reading the counts.
const std = @import("std");
const Io = std.Io;

var base: Io = undefined;
var vtable: Io.VTable = undefined;
var inline_groups: bool = false;
var async_count: std.atomic.Value(usize) = .init(0);
var concurrent_count: std.atomic.Value(usize) = .init(0);
pub var group_async: std.atomic.Value(usize) = .init(0);
var group_concurrent: std.atomic.Value(usize) = .init(0);

pub fn wrap(io: Io) Io {
    base = io;
    inline_groups = false;
    async_count.store(0, .monotonic);
    concurrent_count.store(0, .monotonic);
    group_async.store(0, .monotonic);
    group_concurrent.store(0, .monotonic);
    vtable = io.vtable.*;
    vtable.async = async;
    vtable.concurrent = concurrent;
    vtable.groupAsync = groupAsync;
    vtable.groupConcurrent = groupConcurrent;
    return .{ .userdata = io.userdata, .vtable = &vtable };
}

/// Resolve nonblocking group work inline too: a single-threaded executor
/// ordinarily refuses concurrent submissions. Forward them as async work
/// so all requested tasks run, with the same group lifetime and awaits.
pub fn wrapInline(io: Io) Io {
    const counted = wrap(io);
    inline_groups = true;
    return counted;
}

pub fn expect(async_groups: usize, concurrent_groups: usize) !void {
    try std.testing.expectEqual(@as(usize, 0), async_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), concurrent_count.load(.monotonic));
    try std.testing.expectEqual(async_groups, group_async.load(.monotonic));
    try std.testing.expectEqual(concurrent_groups, group_concurrent.load(.monotonic));
}

fn async(userdata: ?*anyopaque, result: []u8, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*const anyopaque, *anyopaque) void) ?*Io.AnyFuture {
    _ = async_count.fetchAdd(1, .monotonic);
    return base.vtable.async(userdata, result, result_alignment, context, context_alignment, start);
}

fn concurrent(userdata: ?*anyopaque, result_len: usize, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*const anyopaque, *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
    _ = concurrent_count.fetchAdd(1, .monotonic);
    return base.vtable.concurrent(userdata, result_len, result_alignment, context, context_alignment, start);
}

fn groupAsync(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*const anyopaque) void) void {
    _ = group_async.fetchAdd(1, .monotonic);
    base.vtable.groupAsync(userdata, group, context, context_alignment, start);
}

fn groupConcurrent(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
    _ = group_concurrent.fetchAdd(1, .monotonic);
    if (inline_groups) return base.vtable.groupAsync(userdata, group, context, context_alignment, start);
    return base.vtable.groupConcurrent(userdata, group, context, context_alignment, start);
}
