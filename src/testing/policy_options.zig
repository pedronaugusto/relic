const std = @import("std");
const relic = @import("../relic.zig");
test "phase2 pattern constructors take defaulted policy options" {
    inline for (.{ relic.worktree.ignore.Rules, relic.worktree.attributes.Attrs, relic.worktree.sparse.Patterns }) |T| {
        const options = @typeInfo(@TypeOf(T.init)).@"fn".param_types[1].?;
        try std.testing.expect(@typeInfo(options) == .@"struct");
    }
    try std.testing.expect(!@hasDecl(relic.worktree.sparse.Patterns, "loadMode"));
    const options = @typeInfo(@TypeOf(relic.worktree.sparse.Patterns.load)).@"fn".param_types[3].?;
    try std.testing.expect(@typeInfo(options) == .@"struct");
}
