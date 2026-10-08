const std = @import("std");
const relic = @import("../relic.zig");
fn inspect(comptime ns: type, comptime prefix: []const u8, comptime depth: usize) usize {
    if (depth == 0) return 0;
    const declarations = switch (@typeInfo(ns)) {
        .@"struct" => |s| s.decl_names,
        .@"union" => |s| s.decl_names,
        .@"enum" => |s| s.decl_names,
        else => return 0,
    };
    var bad: usize = 0;
    inline for (declarations) |name| {
        const value = @field(ns, name);
        const path = if (prefix.len == 0) name else prefix ++ "." ++ name;
        if (@TypeOf(value) == type) {
            bad += inspect(value, path, depth - 1);
        } else if (@typeInfo(@TypeOf(value)) == .@"fn") {
            const count = @typeInfo(@TypeOf(value)).@"fn".param_types.len;
            if (count > 5) {
                std.debug.print("public positional inputs: {s} {d}\n", .{ path, count });
                bad += 1;
            }
        }
    }
    return bad;
}
test "phase2 entire public surface stays within five positional inputs" {
    @setEvalBranchQuota(1000000);
    try std.testing.expectEqual(@as(usize, 0), inspect(relic, "", 7));
}
