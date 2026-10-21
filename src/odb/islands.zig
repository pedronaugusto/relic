//! Delta islands, the pack writer's side (git's `in_same_island`): which
//! islands each object belongs to, and whether one may be written as a
//! delta of another.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Oid = @import("../hash/hash.zig").Oid;

pub const Error = Allocator.Error;

/// Each object's islands, a bit each. Release with `deinit`.
pub const Islands = struct {
    pub const Error = Allocator.Error;

    arena: std.heap.ArenaAllocator,
    marks: Oid.Map([]u64) = .empty,
    words: usize,

    pub fn init(gpa: Allocator, count: usize) Islands {
        return .{ .arena = .init(gpa), .words = count / 64 + 1 };
    }

    pub fn deinit(i: *Islands) void {
        i.arena.deinit();
        i.* = undefined;
    }

    /// `oid` is in island `island`.
    pub fn mark(i: *Islands, oid: Oid, island: usize) Allocator.Error!void {
        const a = i.arena.allocator();
        const slot = try i.marks.getOrPut(a, oid);
        if (!slot.found_existing) {
            slot.value_ptr.* = try a.alloc(u64, i.words);
            @memset(slot.value_ptr.*, 0);
        }
        slot.value_ptr.*[island / 64] |= @as(u64, 1) << @intCast(island % 64);
    }

    /// git's `in_same_island`: an object in no island may be a delta of
    /// anything; an object in no island may be no one's base; else the
    /// base must be in every island the object is.
    pub fn allows(i: *const Islands, target: Oid, base: Oid) bool {
        const t = i.marks.get(target) orelse return true;
        const b = i.marks.get(base) orelse return false;
        for (t, b) |tw, bw| if (tw & ~bw != 0) return false;
        return true;
    }
};
