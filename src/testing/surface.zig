//! Contracts for the namespaces users import.
const std = @import("std");
const relic = @import("../relic.zig");

fn isNamespace(comptime ns: type, comptime name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    const value = @field(ns, name);
    if (@TypeOf(value) != type) return false;
    return switch (@typeInfo(value)) {
        .@"struct" => |s| s.field_names.len == 0 and !s.is_tuple,
        else => false,
    };
}

fn tableCount(text: []const u8, comptime path: []const u8) usize {
    const needle = "| `" ++ path ++ "` |";
    var count: usize = 0;
    var rest = text;
    while (std.mem.find(u8, rest, needle)) |at| {
        count += 1;
        rest = rest[at + needle.len ..];
    }
    return count;
}

fn checkTree(comptime ns: type, comptime prefix: []const u8, comptime depth: usize, readme: []const u8) !usize {
    var count: usize = 0;
    inline for (@typeInfo(ns).@"struct".decl_names) |name| {
        if (comptime isNamespace(ns, name)) {
            const path = if (prefix.len == 0) name else prefix ++ "." ++ name;
            try std.testing.expectEqual(@as(usize, 1), comptime tableCount(@embedFile("../relic.zig"), path));
            try std.testing.expectEqual(@as(usize, 1), tableCount(readme, path));
            try std.testing.expect(!@hasDecl(@field(ns, name), "test_access"));
            inline for (@typeInfo(ns).@"struct".decl_names) |other| {
                if (comptime isNamespace(ns, other) and !std.mem.eql(u8, name, other))
                    try std.testing.expect(@field(ns, name) != @field(ns, other));
            }
            count += 1;
            if (depth > 1) count += try checkTree(@field(ns, name), path, depth - 1, readme);
        }
    }
    return count;
}

fn rows(text: []const u8) usize {
    return std.mem.count(u8, text, "\n| `") + std.mem.count(u8, text, "\n//! | `");
}

test "phase2 module tables equal the exported namespace tree" {
    @setEvalBranchQuota(500000);
    const readme = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "README.md", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(readme);
    const count = try checkTree(relic, "", 3, readme);
    try std.testing.expectEqual(count, comptime rows(@embedFile("../relic.zig")));
    const start = std.mem.find(u8, readme, "<!-- BEGIN PHASE2 MODULES -->").?;
    const end = std.mem.find(u8, readme, "<!-- END PHASE2 MODULES -->").?;
    try std.testing.expectEqual(count, rows(readme[start..end]));
}

fn covers(comptime facade: type, comptime implementation: type) !void {
    inline for (@typeInfo(implementation).@"struct".decl_names) |name| {
        try std.testing.expect(@hasDecl(facade, name));
        if (@hasDecl(facade, name))
            try std.testing.expect(@TypeOf(@field(facade, name)) == @TypeOf(@field(implementation, name)));
    }
}

test "phase2 publishing facades cover every implementation declaration" {
    try covers(relic.repo, @import("../repo/repo.zig"));
    try covers(relic.hash, @import("../hash/hash.zig"));
    try covers(relic.object, @import("../object/object.zig"));
    try covers(relic.odb, @import("../odb/odb.zig"));
    try covers(relic.refs, @import("../refs/refs.zig"));
    try covers(relic.config, @import("../config/config.zig"));
    try covers(relic.index, @import("../index/index.zig"));
    try covers(relic.worktree, @import("../checkout/checkout.zig"));
    try covers(relic.diff, @import("../diff/diff.zig"));
    try covers(relic.revwalk, @import("../walk/walk.zig"));
    try covers(relic.merge, @import("../merge/merge.zig"));
    try covers(relic.commit, @import("../commit/commit.zig"));
    try covers(relic.transport, @import("../transport/transport.zig"));
    try covers(relic.submodule, @import("../submodule/submodule.zig"));
    try covers(relic.lfs, @import("../lfs/lfs.zig"));
    try covers(relic.patch, @import("../patch/patch.zig"));
    try covers(relic.pretty, @import("../pretty/pretty.zig"));
    try covers(relic.maintenance, @import("../maintenance/maintenance.zig"));
}
