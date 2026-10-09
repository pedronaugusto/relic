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

test "phase2 public operations keep policy in option fields" {
    inline for (.{ relic.repo.hooks.Runner.postMerge, relic.commit.hooks.Hooks.init, relic.commit.trailer.block, relic.revwalk.mailmap.Mailmap.addFileAt, relic.lfs.api.gitRemoteUrl, relic.lfs.FetchPattern.compile, relic.transport.remotehelper.Helper.list, relic.pretty.refs.Listing.write, relic.transport.policy.allowed }) |operation| {
        inline for (@typeInfo(@TypeOf(operation)).@"fn".param_types) |parameter| {
            if (parameter) |T| try std.testing.expect(T != bool and T != ?bool);
        }
    }
}
