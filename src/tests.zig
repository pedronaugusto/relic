pub const repo = @import("repo/repo.zig");
pub const hash = @import("hash/hash.zig");
pub const object = @import("object/object.zig");
pub const odb = @import("odb/odb.zig");
pub const refs = @import("refs/refs.zig");
pub const config = @import("config/config.zig");
pub const index = @import("index/index.zig");
pub const worktree = @import("checkout/checkout.zig");
pub const diff = @import("diff/diff.zig");
pub const revwalk = @import("walk/walk.zig");
pub const merge = @import("merge/merge.zig");
pub const commit = @import("commit/commit.zig");
pub const transport = @import("transport/transport.zig");
pub const submodule = @import("submodule/submodule.zig");
pub const lfs = @import("lfs/lfs.zig");
pub const patch = @import("patch/patch.zig");
pub const grep = @import("grep.zig");
pub const archive = @import("archive.zig");
pub const pretty = @import("pretty/pretty.zig");
pub const clean = @import("clean.zig");
pub const fastimport = @import("fastimport.zig");
pub const fastexport = @import("fastexport.zig");
pub const maintenance = @import("maintenance/maintenance.zig");

const std = @import("std");
const api_mod = @import("lfs/api.zig");
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
    try std.testing.expect(!@hasDecl(api_mod, "timeoutsFor"));
    try std.testing.expect(!@hasField(api_mod.Exchange, "response"));
    try std.testing.expect(!@hasField(api_mod.Exchange, "diagnostics"));
    const wire = @typeInfo(@FieldType(api_mod.Exchange, "wire")).pointer.child;
    try std.testing.expect(@typeInfo(wire) == .@"opaque");
    const pool = @typeInfo(@FieldType(api_mod.Client, "transports")).optional.child;
    try std.testing.expect(@typeInfo(@typeInfo(pool).pointer.child) == .@"opaque");
}

test {
    _ = @import("testing/policy_options.zig");
    // Every module the API reaches, one level down as well as at the top,
    // so that every file under the root is compiled and its tests run.
    std.testing.refAllDecls(relic);
    inline for (@typeInfo(relic).@"struct".decl_names) |name| {
        std.testing.refAllDecls(@field(relic, name));
    }
    if (builtin.is_test) {
        // the plumbing the API keeps to itself: reached by no public name,
        // so named here for its tests to run
        _ = @import("codec/varint.zig");
        _ = @import("odb/keep.zig");
        _ = @import("names/ref.zig");
        _ = @import("refs/refs_test.zig");
        _ = @import("discover/format.zig");
        _ = @import("codec/ewah.zig");
        _ = @import("text/ere.zig");
        _ = @import("fs/stat.zig");
        _ = @import("lfs/timetext.zig");
        _ = @import("lfs/mimesniff.zig");
        _ = @import("config/write.zig");
        _ = @import("testing/git.zig");
        _ = @import("testing/bytes.zig");
        _ = @import("testing/helpers.zig");
        _ = @import("testing/fixtures.zig");
        _ = @import("maintenance/maintenance_test.zig");
        _ = @import("checkout/checkout_test.zig");
        _ = @import("repo/repo_test.zig");
        _ = @import("testing/concurrency.zig");
        _ = @import("testing/workcount.zig");
        _ = @import("testing/packwrite.zig");
        _ = @import("diff/diff_test.zig");
        _ = @import("diff/blame_test.zig");
        _ = @import("submodule/submodule_test.zig");
        _ = @import("checkout/filter_test.zig");
        _ = @import("lfs/lfs_test.zig");
        _ = @import("testing/eol.zig");
        _ = @import("testing/encoding.zig");
        _ = @import("testing/remote.zig");
        _ = @import("transport/transport_test.zig");
        _ = @import("commit/stash_test.zig");
        _ = @import("worktree/snapshot_test.zig");
        _ = @import("object/signing_test.zig");
        _ = @import("testing/embedded_repo.zig");
        _ = @import("testing/config_refresh.zig");
        _ = @import("testing/lfs.zig");
        _ = @import("lfs/transfer_test.zig");
        _ = @import("lfs/locks_test.zig");
        _ = @import("lfs/push_test.zig");
        _ = @import("lfs/ssh_test.zig");
        _ = @import("wire/auth_test.zig");
        _ = @import("walk/walk_test.zig");
        _ = @import("walk/shallow_test.zig");
        _ = @import("transport/partial_test.zig");
        _ = @import("testing/history.zig");
        _ = @import("merge/ort_test.zig");
        _ = @import("transport/uploadpack_test.zig");
        _ = @import("testing/cloneconfig.zig");
        _ = @import("wire/clientcert_test.zig");
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
        _ = @import("checkout/fsmonitor_test.zig");
        _ = @import("patch/rangediff_test.zig");
        _ = @import("pretty/refs_test.zig");
        _ = @import("object/trailer_test.zig");
        _ = @import("repo/safe_test.zig");
        _ = @import("wire/hidden.zig");
        _ = @import("wire/hidden_test.zig");
        _ = @import("wire/promisors.zig");
        _ = @import("wire/promisors_test.zig");
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
    _ = @import("testing/pack_keep.zig");
    _ = @import("testing/objectwalk.zig");
    _ = @import("testing/fetchpack.zig");
    _ = @import("refs/packed.zig");
}

// Keep every moved source-test family explicit for the shared reachability gate.
test {
    _ = @import("commit/notes.zig");
    _ = @import("commit/reset.zig");
    _ = @import("commit/todo.zig");
    _ = @import("text/cquote.zig");
    _ = @import("text/glob.zig");
    _ = @import("text/glob_test.zig");
    _ = @import("diff/patchid.zig");
    _ = @import("diff/similarity.zig");
    _ = @import("lfs/netrc.zig");
    _ = @import("lfs/ssh.zig");
    _ = @import("merge/strategy.zig");
    _ = @import("merge/subtreeshift.zig");
    _ = @import("object/fsck.zig");
    _ = @import("text/date.zig");
    _ = @import("odb/abbrev.zig");
    _ = @import("odb/indexpack.zig");
    _ = @import("patch/binary.zig");
    _ = @import("mail/mail.zig");
    _ = @import("mail/format.zig");
    _ = @import("patch/whitespace.zig");
    _ = @import("patterns/pathspec.zig");
    _ = @import("pretty/pretty.zig");
    _ = @import("revwalk/bisect.zig");
    _ = @import("revwalk/describe.zig");
    _ = @import("revwalk/mailmap.zig");
    _ = @import("revwalk/revparse.zig");
    _ = @import("walk/shallow.zig");
    _ = @import("pretty/shortlog.zig");
    _ = @import("discover/gitlink.zig");
    _ = @import("config/gitmodules.zig");
    _ = @import("submodule/transport.zig");
    _ = @import("transport/bundle.zig");
    _ = @import("wire/connection.zig");
    _ = @import("wire/fetchpack.zig");
    _ = @import("wire/filterspec.zig");
    _ = @import("wire/httpsettings.zig");
    _ = @import("codec/pktline.zig");
    _ = @import("wire/protocol.zig");
    _ = @import("wire/refspec.zig");
    _ = @import("wire/remote.zig");
    _ = @import("wire/sendpack.zig");
    _ = @import("wire/sideband.zig");
    _ = @import("wire/smarthttp.zig");
    _ = @import("wire/ssh.zig");
    _ = @import("transport/uploadpack.zig");
    _ = @import("text/unicodewidth.zig");
    _ = @import("checkout/convert.zig");
    _ = @import("checkout/dirscan.zig");
    _ = @import("names/path.zig");
    _ = @import("worktree/sparsecheckout.zig");
    _ = @import("diff/userdiff.zig");
    _ = @import("lfs/custom.zig");
    _ = @import("merge/octopus.zig");
    _ = @import("transport/remotehelper.zig");
    _ = @import("wire/policy.zig");
    _ = @import("text/encoding.zig");
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

test {
    _ = @import("testing/surface.zig");
}

test {
    _ = @import("testing/public_calls.zig");
}

test {
    _ = @import("testing/codec_object.zig");
}
