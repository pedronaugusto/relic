//! relic — read and write a git repository from Zig.

pub const hash = @import("hash.zig");
pub const object = @import("object.zig");
pub const fs = @import("fs.zig");
pub const delta = @import("delta.zig");
pub const pack = @import("pack.zig");
pub const odb = @import("odb.zig");
pub const index = @import("index.zig");
pub const varint = @import("varint.zig");
pub const ewah = @import("ewah.zig");
pub const safepath = @import("safepath.zig");
pub const platstat = @import("platstat.zig");
pub const refs = @import("refs.zig");
pub const reflog = @import("reflog.zig");
pub const config = @import("config.zig");
pub const wildmatch = @import("wildmatch.zig");
pub const ignore = @import("ignore.zig");
pub const attributes = @import("attributes.zig");
pub const worktree = @import("worktree.zig");
pub const worktrees = @import("worktrees.zig");
pub const repo = @import("repo.zig");
pub const revwalk = @import("revwalk.zig");
pub const merge = @import("merge.zig");
pub const commitgraph = @import("commitgraph.zig");
pub const midx = @import("midx.zig");

const builtin = @import("builtin");

test {
    @import("std").testing.refAllDecls(@This());
    if (builtin.is_test) {
        _ = @import("testgit.zig");
        _ = @import("fixture_test.zig");
        _ = @import("worktree_test.zig");
        _ = @import("repo_test.zig");
        _ = @import("concurrency_test.zig");
        _ = @import("bench_test.zig");
    }
}
