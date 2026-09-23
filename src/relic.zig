//! relic — read and write a git repository from Zig.

pub const sha1 = @import("sha1.zig");
pub const sha1dc = @import("sha1dc.zig");
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
pub const dirscan = @import("dirscan.zig");
pub const refs = @import("refs.zig");
pub const reflog = @import("reflog.zig");
pub const config = @import("config.zig");
pub const wildmatch = @import("wildmatch.zig");
pub const ignore = @import("ignore.zig");
pub const attributes = @import("attributes.zig");
pub const worktree = @import("worktree.zig");
pub const worktrees = @import("worktrees.zig");
pub const sparse = @import("sparse.zig");
pub const repo = @import("repo.zig");
pub const revwalk = @import("revwalk.zig");
pub const merge = @import("merge.zig");
pub const commitgraph = @import("commitgraph.zig");
pub const midx = @import("midx.zig");
pub const textdiff = @import("textdiff.zig");
pub const diff = @import("diff.zig");
pub const pktline = @import("pktline.zig");
pub const program = @import("program.zig");
pub const gitmodules = @import("gitmodules.zig");
pub const gitlink = @import("gitlink.zig");
pub const submodule = @import("submodule.zig");
pub const filter = @import("filter.zig");
pub const lfs = @import("lfs.zig");
pub const convert = @import("convert.zig");
pub const refspec = @import("refspec.zig");
pub const url = @import("url.zig");
pub const remote = @import("remote.zig");
pub const progress = @import("progress.zig");
pub const fsck = @import("fsck.zig");
pub const indexpack = @import("indexpack.zig");
pub const connection = @import("connection.zig");
pub const sideband = @import("sideband.zig");
pub const protocol = @import("protocol.zig");
pub const objectwalk = @import("objectwalk.zig");
pub const fetchpack = @import("fetchpack.zig");
pub const local = @import("local.zig");
pub const ssh = @import("ssh.zig");
pub const credential = @import("credential.zig");
pub const smarthttp = @import("smarthttp.zig");
pub const transport = @import("transport.zig");
pub const fetch = @import("fetch.zig");
pub const clone = @import("clone.zig");
pub const sendpack = @import("sendpack.zig");
pub const push = @import("push.zig");
pub const hooks = @import("hooks.zig");
pub const commit = @import("commit.zig");
pub const stash = @import("stash.zig");
pub const signing = @import("signing.zig");

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
        _ = @import("diff_test.zig");
        _ = @import("submodule_test.zig");
        _ = @import("filter_test.zig");
        _ = @import("lfs_test.zig");
        _ = @import("eol_test.zig");
        _ = @import("testremote.zig");
        _ = @import("transport_test.zig");
        _ = @import("stash_test.zig");
        _ = @import("signing_test.zig");
    }
}
