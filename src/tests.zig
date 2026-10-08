pub const repo = @import("repo.zig");
pub const hash = @import("hash.zig");
pub const object = @import("object.zig");
pub const odb = @import("odb.zig");
pub const refs = @import("refs.zig");
pub const config = @import("config.zig");
pub const index = @import("index.zig");
pub const worktree = @import("worktree.zig");
pub const diff = @import("diff.zig");
pub const revwalk = @import("revwalk.zig");
pub const merge = @import("merge.zig");
pub const commit = @import("commit.zig");
pub const transport = @import("transport.zig");
pub const submodule = @import("submodule.zig");
pub const lfs = @import("lfs.zig");
pub const patch = @import("patch.zig");
pub const grep = @import("grep.zig");
pub const archive = @import("archive.zig");
pub const pretty = @import("pretty.zig");
pub const clean = @import("clean.zig");

const std = @import("std");
const builtin = @import("builtin");
const relic = @import("relic.zig");

test "the plumbing is relic's own: no public name reaches it" {
    try std.testing.expect(!@hasDecl(odb, "varint"));
    try std.testing.expect(!@hasDecl(index, "ewah"));
    try std.testing.expect(!@hasDecl(revwalk, "ere"));
    try std.testing.expect(!@hasDecl(worktree, "platstat"));
    try std.testing.expect(!@hasDecl(lfs, "timetext"));
    try std.testing.expect(!@hasDecl(lfs, "mimesniff"));
    try std.testing.expect(!@hasDecl(transport, "httpclient"));
    try std.testing.expect(!@hasDecl(transport, "httpauth"));
    try std.testing.expect(!@hasDecl(transport, "tls"));
    try std.testing.expect(!@hasDecl(transport, "clientcert"));
    try std.testing.expect(!@hasDecl(lfs.lfsapi, "timeoutsFor"));
    try std.testing.expect(!@hasField(lfs.lfsapi.Exchange, "response"));
    try std.testing.expect(!@hasField(lfs.lfsapi.Exchange, "diagnostics"));
    const wire = @typeInfo(@FieldType(lfs.lfsapi.Exchange, "wire")).pointer.child;
    try std.testing.expect(@typeInfo(wire) == .@"opaque");
    const pool = @typeInfo(@FieldType(lfs.lfsapi.Client, "transports")).optional.child;
    try std.testing.expect(@typeInfo(@typeInfo(pool).pointer.child) == .@"opaque");
}

test {
    // Every module the API reaches, one level down as well as at the top,
    // so that every file under the root is compiled and its tests run.
    std.testing.refAllDecls(relic);
    inline for (@typeInfo(relic).@"struct".decl_names) |name| {
        std.testing.refAllDecls(@field(relic, name));
    }
    if (builtin.is_test) {
        // the plumbing the API keeps to itself: reached by no public name,
        // so named here for its tests to run
        _ = @import("varint.zig");
        _ = @import("names/ref.zig");
        _ = @import("refs_test.zig");
        _ = @import("discover/format.zig");
        _ = @import("crc32.zig");
        _ = @import("ewah.zig");
        _ = @import("ere.zig");
        _ = @import("repo/fs/stat.zig");
        _ = @import("lfs/timetext.zig");
        _ = @import("lfs/mimesniff.zig");
        _ = @import("config/write.zig");
        _ = @import("testing/git.zig");
        _ = @import("testing/allocation.zig");
        _ = @import("testing/bytes.zig");
        _ = @import("testing/helpers.zig");
        _ = @import("testing/fixtures.zig");
        _ = @import("odb/accelerators_test.zig");
        _ = @import("worktree_test.zig");
        _ = @import("repo_test.zig");
        _ = @import("testing/concurrency.zig");
        _ = @import("testing/workcount.zig");
        _ = @import("testing/packwrite.zig");
        _ = @import("diff_test.zig");
        _ = @import("diff/blame_test.zig");
        _ = @import("submodule_test.zig");
        _ = @import("worktree/filter_test.zig");
        _ = @import("lfs_test.zig");
        _ = @import("testing/eol.zig");
        _ = @import("testing/encoding.zig");
        _ = @import("testing/remote.zig");
        _ = @import("transport_test.zig");
        _ = @import("commit/stash_test.zig");
        _ = @import("worktree/snapshot_test.zig");
        _ = @import("commit/signing_test.zig");
        _ = @import("testing/embedded_repo.zig");
        _ = @import("testing/config_refresh.zig");
        _ = @import("testing/lfs.zig");
        _ = @import("lfs/transfer_test.zig");
        _ = @import("lfs/locks_test.zig");
        _ = @import("lfs/push_test.zig");
        _ = @import("lfs/ssh_test.zig");
        _ = @import("transport/auth_test.zig");
        _ = @import("revwalk_test.zig");
        _ = @import("revwalk/shallow_test.zig");
        _ = @import("transport/partial_test.zig");
        _ = @import("testing/history.zig");
        _ = @import("merge/ort_test.zig");
        _ = @import("transport/uploadpack_test.zig");
        _ = @import("testing/cloneconfig.zig");
        _ = @import("transport/clientcert_test.zig");
        _ = @import("odb/inflate_test.zig");
        _ = @import("merge/strategy_test.zig");
        _ = @import("transport/bundle_test.zig");
        _ = @import("patch/apply_test.zig");
        _ = @import("patch/format_test.zig");
        _ = @import("patch/am_test.zig");
        _ = @import("grep_test.zig");
        _ = @import("archive_test.zig");
        _ = @import("clean_test.zig");
        _ = @import("fastimport_test.zig");
        _ = @import("fastexport_test.zig");
        _ = @import("transport/remotehelper_test.zig");
        _ = @import("lfs/custom_test.zig");
        _ = @import("worktree/fsmonitor_test.zig");
        _ = @import("patch/rangediff_test.zig");
        _ = @import("refs/filter_test.zig");
        _ = @import("commit/trailer_test.zig");
        _ = @import("repo/safe_test.zig");
        _ = @import("transport/hidden.zig");
        _ = @import("transport/hidden_test.zig");
        _ = @import("transport/promisors.zig");
        _ = @import("transport/promisors_test.zig");
        _ = @import("testing/shared.zig");
        _ = @import("repo/ident_test.zig");
    }
}

test {
    _ = @import("odb/revindex_test.zig");
    _ = @import("index/sparseindex_test.zig");
    _ = @import("refs/reftablestack_test.zig");
    _ = @import("testing/url_ownership.zig");
    _ = @import("testing/refs_ownership.zig");
    _ = @import("refs/packed.zig");
}

// Keep every moved source-test family explicit for the shared reachability gate.
test {
    _ = @import("commit/notes.zig");
    _ = @import("commit/reset.zig");
    _ = @import("commit/todo.zig");
    _ = @import("cquote.zig");
    _ = @import("text/glob.zig");
    _ = @import("text/glob_test.zig");
    _ = @import("diff/patchid.zig");
    _ = @import("diff/similarity.zig");
    _ = @import("lfs/netrc.zig");
    _ = @import("lfs/ssh.zig");
    _ = @import("merge/strategy.zig");
    _ = @import("merge/subtreeshift.zig");
    _ = @import("object/fsck.zig");
    _ = @import("object/gitdate.zig");
    _ = @import("odb/abbrev.zig");
    _ = @import("odb/indexpack.zig");
    _ = @import("patch/binary.zig");
    _ = @import("patch/mail.zig");
    _ = @import("patch/mail/format.zig");
    _ = @import("patch/whitespace.zig");
    _ = @import("pathspec.zig");
    _ = @import("pretty.zig");
    _ = @import("revwalk/bisect.zig");
    _ = @import("revwalk/describe.zig");
    _ = @import("revwalk/mailmap.zig");
    _ = @import("revwalk/revparse.zig");
    _ = @import("revwalk/shallow.zig");
    _ = @import("revwalk/shortlog.zig");
    _ = @import("submodule/gitlink.zig");
    _ = @import("submodule/gitmodules.zig");
    _ = @import("submodule/transport.zig");
    _ = @import("transport/bundle.zig");
    _ = @import("transport/connection.zig");
    _ = @import("transport/fetchpack.zig");
    _ = @import("transport/filterspec.zig");
    _ = @import("transport/httpsettings.zig");
    _ = @import("transport/pktline.zig");
    _ = @import("transport/protocol.zig");
    _ = @import("transport/refspec.zig");
    _ = @import("transport/remote.zig");
    _ = @import("transport/sendpack.zig");
    _ = @import("transport/sideband.zig");
    _ = @import("transport/smarthttp.zig");
    _ = @import("transport/ssh.zig");
    _ = @import("transport/uploadpack.zig");
    _ = @import("unicodewidth.zig");
    _ = @import("worktree/convert.zig");
    _ = @import("worktree/dirscan.zig");
    _ = @import("worktree/safepath.zig");
    _ = @import("worktree/sparsecheckout.zig");
    _ = @import("diff/userdiff.zig");
    _ = @import("lfs/custom.zig");
    _ = @import("merge/octopus.zig");
    _ = @import("transport/remotehelper.zig");
    _ = @import("transport/policy.zig");
    _ = @import("worktree/encoding.zig");
}

// git's published security fixes, one file per class of hole, each test
// named for the fix and the git test it mirrors.
test {
    _ = @import("testing/security/buffer_overflow.zig");
    _ = @import("testing/security/config_injection.zig");
    _ = @import("testing/security/config_quoting.zig");
    _ = @import("testing/security/credential_injection.zig");
    _ = @import("testing/security/credential_leak.zig");
    _ = @import("testing/security/dos_memory.zig");
    _ = @import("testing/security/file_write.zig");
    _ = @import("testing/security/hardlink.zig");
    _ = @import("testing/security/hash_collision.zig");
    _ = @import("testing/security/hook_write.zig");
    _ = @import("testing/security/integer_overflow.zig");
    _ = @import("testing/security/lazy_fetch.zig");
    _ = @import("testing/security/option_injection.zig");
    _ = @import("testing/security/path_alias.zig");
    _ = @import("testing/security/path_search.zig");
    _ = @import("testing/security/protocol_injection.zig");
    _ = @import("testing/security/protocol_policy.zig");
    _ = @import("testing/security/repo_ownership.zig");
    _ = @import("testing/security/submodule_gitdir.zig");
    _ = @import("testing/security/submodule_name.zig");
    _ = @import("testing/security/symlink_traversal.zig");
    _ = @import("testing/security/terminal_escape.zig");
}
