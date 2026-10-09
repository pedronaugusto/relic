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

test "phase2 conversion handles use open and explicit cleanup Io" {
    const Session = relic.worktree.convert.Session;
    try std.testing.expect(@hasDecl(Session, "open"));
    try std.testing.expect(!@hasDecl(Session, "init"));
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(Session.deinit)).@"fn".param_types.len);
}

test "phase2 conversion operations receive Io per call" {
    const Session = relic.worktree.convert.Session;
    try std.testing.expect(!@hasField(Session, "io"));
    inline for (.{ Session.toGit, Session.toGitFile, Session.toWorktree, Session.renormalize, Session.nextReady }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types[2].? == std.Io);
    }
}
