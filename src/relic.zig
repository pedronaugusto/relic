//! relic — read and write a git repository from Zig.
//!
//! The API is one module per concern, and each of those holds the modules
//! that belong to it: `relic.refs` is refs and their transactions, and
//! `relic.refs.reflog` is the log beside them.
//!
//! | Module | What it is | Under it |
//! |---|---|---|
//! | `repo` | `Repository`: open or create one, and reach the rest from it. | `hooks`, `program`, `warning`, `fs` |
//! | `hash` | `Oid`, `Kind`, `Hasher`: object names, SHA-1 or SHA-256. | `sha1`, `sha1dc` |
//! | `object` | `Commit`, `Tree`, `Tag`, `Signature`: objects as bytes. | `fsck` |
//! | `odb` | `Odb`: loose objects, packs, alternates. | `pack`, `delta`, `inflate`, `indexpack`, `revindex`, `commitgraph`, `midx`, `abbrev` |
//! | `refs` | `Store`, `Transaction`: loose refs and `packed-refs`. | `reflog`, `reftable`, `reftablestack` |
//! | `config` | `Config`: git's configuration files, lossless. | `userconfig` |
//! | `index` | `Index`: the `DIRC` file, versions 2 to 4. | `sparseindex` |
//! | `worktree` | Staging, writing a tree, checking one out, status. | `worktrees`, `sparse`, `sparsecheckout`, `ignore`, `attributes`, `wildmatch`, `convert`, `filter`, `dirscan`, `safepath` |
//! | `wildmatch` | Match a glob directly with git's pathname and case-fold flags. | |
//! | `diff` | Tree against tree, blob against blob, unified text. | `textdiff`, `rename`, `similarity`, `patchid` |
//! | `revwalk` | Walking history, merge bases. | `revparse`, `shallow` |
//! | `merge` | Three-way merges of contents and trees. | `blobmerge`, `ort`, `strategy`, `subtreeshift`, `threeway`, `rerere` |
//! | `commit` | Making a commit as `git commit` does. | `message`, `head`, `reset`, `stash`, `signing`, `commithooks`, `merging`, `sequencer`, `rebase`, `todo` |
//! | `transport` | `Session`: a remote, open. | `remote`, `url`, `refspec`, `fetch`, `fetchpack`, `clone`, `push`, `sendpack`, `local`, `ssh`, `smarthttp`, `httpclient`, `tls`, `clientcert`, `httpauth`, `httpsettings`, `credential`, `auth`, `protocol`, `connection`, `pktline`, `sideband`, `uploadpack`, `objectwalk`, `objectfilter`, `partial`, `filterspec`, `progress` |
//! | `submodule` | Submodules: status, init, update, sync, absorb. | `gitmodules`, `gitlink`, `submoduletransport` |
//! | `lfs` | Git LFS in process: pointers and the store. | `lfsapi`, `lfstransfer`, `lfslocks`, `lfspush`, `lfshooks`, `lfsssh`, `netrc` |

pub const repo = @import("repo.zig");
pub const hash = @import("hash.zig");
pub const object = @import("object.zig");
pub const odb = @import("odb.zig");
pub const refs = @import("refs.zig");
pub const config = @import("config.zig");
pub const index = @import("index.zig");
pub const worktree = @import("worktree.zig");
/// Match a glob with git's pathname and case-fold flags.
pub const wildmatch = @import("wildmatch.zig");
pub const diff = @import("diff.zig");
pub const revwalk = @import("revwalk.zig");
pub const merge = @import("merge.zig");
pub const commit = @import("commit.zig");
pub const transport = @import("transport.zig");
pub const submodule = @import("submodule.zig");
pub const lfs = @import("lfs.zig");

const builtin = @import("builtin");

test "public wildmatch follows git pathname and case-fold cases" {
    const std = @import("std");
    try std.testing.expect(try wildmatch.match("a/**/b", "a/x/y/b", .{ .pathname = true }));
    try std.testing.expect(!try wildmatch.match("*.c", "sub/foo.c", .{ .pathname = true }));
    try std.testing.expect(try wildmatch.match("*.c", "sub/foo.c", .{ .pathname = false }));
    try std.testing.expect(try wildmatch.match("*.TXT", "readme.txt", .{ .case_fold = true }));
}

test "the plumbing is relic's own: no public name reaches it" {
    const std = @import("std");
    try std.testing.expect(!@hasDecl(odb, "varint"));
    try std.testing.expect(!@hasDecl(index, "ewah"));
    try std.testing.expect(!@hasDecl(revwalk, "ere"));
    try std.testing.expect(!@hasDecl(worktree, "platstat"));
    try std.testing.expect(!@hasDecl(lfs, "timetext"));
    try std.testing.expect(!@hasDecl(lfs, "mimesniff"));
}

test {
    const std = @import("std");
    // Every module the API reaches, one level down as well as at the top,
    // so that every file under the root is compiled and its tests run.
    std.testing.refAllDecls(@This());
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        std.testing.refAllDecls(@field(@This(), decl.name));
    }
    if (builtin.is_test) {
        // the plumbing the API keeps to itself: reached by no public name,
        // so named here for its tests to run
        _ = @import("varint.zig");
        _ = @import("ewah.zig");
        _ = @import("ere.zig");
        _ = @import("platstat.zig");
        _ = @import("timetext.zig");
        _ = @import("mimesniff.zig");
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
        _ = @import("embedded_repo_test.zig");
        _ = @import("config_refresh_test.zig");
        _ = @import("testlfs.zig");
        _ = @import("lfstransfer_test.zig");
        _ = @import("lfslocks_test.zig");
        _ = @import("lfspush_test.zig");
        _ = @import("lfsssh_test.zig");
        _ = @import("auth_test.zig");
        _ = @import("revwalk_test.zig");
        _ = @import("shallow_test.zig");
        _ = @import("partial_test.zig");
        _ = @import("history_test.zig");
        _ = @import("ort_test.zig");
        _ = @import("uploadpack_test.zig");
        _ = @import("cloneconfig_test.zig");
        _ = @import("clientcert_test.zig");
        _ = @import("inflate_test.zig");
        _ = @import("strategy_test.zig");
        _ = @import("tls_fork_test.zig");
    }
}
