//! A backing allocator for `std.testing.checkAllAllocationFailures` that
//! never resizes a block in place. The check counts a first run's
//! allocations, then fails each in turn. `std.testing.allocator` resizes
//! some blocks in place and not others, run to run, and each refusal is one
//! more allocation, so the count moved between runs. Refusing every resize
//! makes each growth an allocation, the same in every run, and the leak
//! check stays `std.testing.allocator`'s.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const no_resize: Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = alloc,
    .resize = Allocator.noResize,
    .remap = Allocator.noRemap,
    .free = free,
} };

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    std.testing.allocator.rawFree(memory, alignment, ret_addr);
}

test "a block grows by moving, every time" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(no_resize);
    try list.appendNTimes(no_resize, 'x', 16);
    try std.testing.expect(!no_resize.resize(list.allocatedSlice(), 64));
    try list.appendNTimes(no_resize, 'y', 64);
    try std.testing.expectEqual(80, list.items.len);
}
