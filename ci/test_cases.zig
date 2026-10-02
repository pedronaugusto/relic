//! Windows runs the same named comparison cases across parallel jobs.
const std = @import("std");
const core_cases = @import("core_cases.zig");

pub const cases = [_][]const u8{
    "core",        "core-formats", "core-worktree", "core-history", "core-transport", "core-integrations", "merge-file", "diff-algorithms", "revwalk",
    "history-0",   "history-1",    "history-2",     "history-3",    "history-4",      "history-5",         "history-6",  "history-7",       "recursive-0",
    "recursive-1", "recursive-2",  "rename-0",      "rename-1",     "rename-2",       "rename-3",          "rename-4",   "rename-5",
};

pub fn filters(b: *std.Build, name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, name, "core")) return &.{};
    for (core_cases.families) |family| if (std.mem.eql(u8, name, family.name)) return family.filters;
    if (std.mem.eql(u8, name, "merge-file")) return &.{"a random corpus of three-way merges matches git merge-file in every style and every algorithm"};
    if (std.mem.eql(u8, name, "diff-algorithms")) return &.{"the histogram, patience and minimal diffs land on the lines git's do, over a random corpus"};
    if (std.mem.eql(u8, name, "revwalk")) {
        const names = b.allocator.alloc([]const u8, 8) catch @panic("out of memory");
        for (names, 0..) |*item, seed| item.* = b.fmt("a walk comes out in git rev-list's order: by date with its ties, hidden commits, topological, reversed: seed {d}", .{seed});
        return names;
    }
    var selected: std.array_list.Managed([]const u8) = .init(b.allocator);
    const families = [_]struct { prefix: []const u8, count: usize, title: []const u8 }{
        .{ .prefix = "history-", .count = 8, .title = "random histories merge to git's trees, stages and messages: seed " },
        .{ .prefix = "recursive-", .count = 3, .title = "criss-cross histories merge their bases first, as git's recursive merge does: seed " },
        .{ .prefix = "rename-", .count = 6, .title = "diff -M, -M30%, -C and --find-copies-harder pair what git's do: seed " },
    };
    for (families) |family| {
        if (!std.mem.startsWith(u8, name, family.prefix)) continue;
        const shard = std.fmt.parseInt(usize, name[family.prefix.len..], 10) catch @panic("invalid test case");
        if (shard >= family.count) @panic("invalid test case");
        var seed = shard;
        while (seed < family.count * 10) : (seed += family.count) {
            if (std.mem.eql(u8, family.prefix, "history-")) {
                // Forty seeds in each density, each named independently.
                if (seed >= 40) continue;
                for ([_][]const u8{ "sparse", "crowded" }) |density| selected.append(b.fmt("{s}{d}, {s}", .{ family.title, seed, density })) catch @panic("out of memory");
            } else {
                // Compilation uses substring filters; the test predicate checks
                // these complete names so seed 1 cannot also run seed 10.
                selected.append(b.fmt("{s}{d}", .{ family.title, seed })) catch @panic("out of memory");
            }
        }
        return selected.toOwnedSlice() catch @panic("out of memory");
    }
    @panic("unknown test case");
}
