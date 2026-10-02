const std = @import("std");
const selection = @import("relic_test_cases");

pub fn selected(name: []const u8) bool {
    if (selection.name.len == 0) return true;
    if (std.mem.eql(u8, selection.name, "core")) return false;
    for (selection.names) |chosen| if (std.mem.eql(u8, name, chosen)) return true;
    return false;
}
