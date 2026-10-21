pub const repo = @import("repo/repo.zig");
pub const hash = @import("hash/hash.zig");
pub const object = @import("object/object.zig");
pub const odb = @import("odb/odb.zig");
pub const refs = @import("refs/refs.zig");
pub const config = @import("config/config.zig");
pub const index = @import("index/index.zig");
pub const worktree = @import("checkout/checkout.zig");
pub const diff = @import("diff/diff.zig");
pub const rev_walk = @import("walk/walk.zig");
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
pub const fast = @import("fast.zig");
pub const maintenance = @import("maintenance/maintenance.zig");

const std = @import("std");
const api_mod = @import("lfs/api.zig");
const builtin = @import("builtin");
const relic = @import("relic.zig");

test "the plumbing is relic's own: no public name reaches it" {
    try std.testing.expect(!@hasDecl(odb, "varint"));
    try std.testing.expect(!@hasDecl(index, "ewah"));
    try std.testing.expect(!@hasDecl(rev_walk, "ere"));
    try std.testing.expect(!@hasDecl(worktree, "platstat"));
    try std.testing.expect(!@hasDecl(lfs, "time_text"));
    try std.testing.expect(!@hasDecl(lfs, "mime_sniff"));
    try std.testing.expect(!@hasDecl(transport, "httpclient"));
    try std.testing.expect(!@hasDecl(transport, "httpauth"));
    try std.testing.expect(!@hasDecl(transport, "tls"));
    try std.testing.expect(!@hasDecl(transport, "client_cert"));
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
        _ = @import("refs/verify_test.zig");
        _ = @import("discover/format.zig");
        _ = @import("discover/gitfile.zig");
        _ = @import("discover/directory.zig");
        _ = @import("codec/ewah.zig");
        _ = @import("text/ere.zig");
        _ = @import("text/percent.zig");
        _ = @import("text/urlmatch.zig");
        _ = @import("text/decimal.zig");
        _ = @import("text/ctype.zig");
        _ = @import("text/quote.zig");
        _ = @import("fs/stat.zig");
        _ = @import("lfs/time_text.zig");
        _ = @import("lfs/mime_sniff.zig");
        _ = @import("config/write.zig");
        _ = @import("testing/git.zig");
        _ = @import("testing/helpers.zig");
        _ = @import("testing/fixtures.zig");
        _ = @import("maintenance/maintenance_test.zig");
        _ = @import("maintenance/gc_test.zig");
        _ = @import("maintenance/prune_test.zig");
        _ = @import("checkout/checkout_test.zig");
        _ = @import("repo/repo_test.zig");
        _ = @import("testing/concurrency.zig");
        _ = @import("testing/work_count.zig");
        _ = @import("testing/pack_write.zig");
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
        _ = @import("worktree/renames_test.zig");
        _ = @import("object/signing_test.zig");
        _ = @import("testing/embedded_repo.zig");
        _ = @import("testing/config_refresh.zig");
        _ = @import("testing/lfs.zig");
        _ = @import("lfs/transfer_test.zig");
        _ = @import("lfs/locks_test.zig");
        _ = @import("lfs/json_test.zig");
        _ = @import("lfs/push_test.zig");
        _ = @import("lfs/ssh_test.zig");
        _ = @import("wire/auth_test.zig");
        _ = @import("walk/walk_test.zig");
        _ = @import("walk/shallow_test.zig");
        _ = @import("transport/partial_test.zig");
        _ = @import("testing/history.zig");
        _ = @import("testing/autostash.zig");
        _ = @import("testing/pull.zig");
        _ = @import("merge/ort_test.zig");
        _ = @import("transport/upload_pack_test.zig");
        _ = @import("transport/receive_pack_test.zig");
        _ = @import("transport/http_backend_test.zig");
        _ = @import("lfs/server_test.zig");
        _ = @import("testing/clone_config.zig");
        _ = @import("wire/client_cert_test.zig");
        _ = @import("wire/pinned_key.zig");
        _ = @import("merge/strategy_test.zig");
        _ = @import("transport/bundle_test.zig");
        _ = @import("transport/bundle/uri_test.zig");
        _ = @import("patch/apply_test.zig");
        _ = @import("patch/format_test.zig");
        _ = @import("patch/am_test.zig");
        _ = @import("commit/in_progress_test.zig");
        _ = @import("grep_test.zig");
        _ = @import("archive_test.zig");
        _ = @import("clean_test.zig");
        _ = @import("fast/importer_test.zig");
        _ = @import("fast/exporter_test.zig");
        _ = @import("transport/remote_helper_test.zig");
        _ = @import("lfs/custom_test.zig");
        _ = @import("checkout/fsmonitor_test.zig");
        _ = @import("checkout/fsmonitor_daemon_test.zig");
        _ = @import("patch/range_diff_test.zig");
        _ = @import("pretty/refs_test.zig");
        _ = @import("pretty/pretty_test.zig");
        _ = @import("object/trailer_test.zig");
        _ = @import("repo/safe_test.zig");
        _ = @import("wire/hidden.zig");
        _ = @import("wire/hidden_test.zig");
        _ = @import("wire/promisors.zig");
        _ = @import("wire/promisors_test.zig");
        _ = @import("wire/url_test.zig");
        _ = @import("wire/credential_test.zig");
        _ = @import("testing/shared.zig");
        _ = @import("repo/ident_test.zig");
    }
}

test {
    _ = @import("odb/rev_index_test.zig");
    _ = @import("index/sparse_index_test.zig");
    _ = @import("refs/reftable/stack_test.zig");
    _ = @import("testing/url_ownership.zig");
    _ = @import("testing/refs_ownership.zig");
    _ = @import("testing/pack_keep.zig");
    _ = @import("testing/fsync.zig");
    _ = @import("testing/crash.zig");
    _ = @import("testing/object_walk.zig");
    _ = @import("testing/fetch_pack.zig");
    _ = @import("refs/packed.zig");
}

// Keep every moved source-test family explicit for the shared reachability gate.
test {
    _ = @import("commit/notes.zig");
    _ = @import("commit/reset.zig");
    _ = @import("commit/todo.zig");
    _ = @import("text/c_quote.zig");
    _ = @import("text/glob.zig");
    _ = @import("text/glob_test.zig");
    _ = @import("text/urlmatch_test.zig");
    _ = @import("diff/patch_id.zig");
    _ = @import("diff/similarity.zig");
    _ = @import("diff/moved.zig");
    _ = @import("checkout/filter.zig");
    _ = @import("codec/delta.zig");
    _ = @import("commit/rebase.zig");
    _ = @import("commit/sequencer.zig");
    _ = @import("commit/stash.zig");
    _ = @import("config/user_config.zig");
    _ = @import("fast/exporter.zig");
    _ = @import("fast/importer.zig");
    _ = @import("grep.zig");
    _ = @import("hash/sha1dc.zig");
    _ = @import("lfs/clone.zig");
    _ = @import("lfs/filter.zig");
    _ = @import("lfs/locks.zig");
    _ = @import("lfs/transfer.zig");
    _ = @import("merge/rerere.zig");
    _ = @import("merge/three_way.zig");
    _ = @import("odb/bitmap.zig");
    _ = @import("odb/commit_graph.zig");
    _ = @import("odb/midx.zig");
    _ = @import("patch/range_diff.zig");
    _ = @import("patterns/attributes.zig");
    _ = @import("patterns/ignore.zig");
    _ = @import("patterns/sparse.zig");
    _ = @import("pretty/refs.zig");
    _ = @import("process/program.zig");
    _ = @import("refs/reflog.zig");
    _ = @import("refs/reftable/stack/transaction.zig");
    _ = @import("refs/reftable/stack/cache.zig");
    _ = @import("repo/safe.zig");
    _ = @import("repo/state.zig");
    _ = @import("report/progress.zig");
    _ = @import("report/warning.zig");
    _ = @import("transport/clone.zig");
    _ = @import("transport/fetch.zig");
    _ = @import("transport/partial.zig");
    _ = @import("transport/push.zig");
    _ = @import("wire/auth.zig");
    _ = @import("wire/client_cert.zig");
    _ = @import("wire/url.zig");
    _ = @import("lfs/netrc.zig");
    _ = @import("lfs/ssh.zig");
    _ = @import("merge/strategy.zig");
    _ = @import("merge/subtree_shift.zig");
    _ = @import("object/fsck.zig");
    _ = @import("text/date.zig");
    _ = @import("odb/abbrev.zig");
    _ = @import("odb/index_pack.zig");
    _ = @import("diff/binary.zig");
    _ = @import("mail/mail.zig");
    _ = @import("mail/format.zig");
    _ = @import("text/whitespace.zig");
    _ = @import("config/color.zig");
    _ = @import("patterns/pathspec.zig");
    _ = @import("pretty/pretty.zig");
    _ = @import("rev_walk/bisect.zig");
    _ = @import("rev_walk/describe.zig");
    _ = @import("rev_walk/mailmap.zig");
    _ = @import("rev_walk/rev_parse.zig");
    _ = @import("walk/shallow.zig");
    _ = @import("pretty/shortlog.zig");
    _ = @import("discover/gitlink.zig");
    _ = @import("config/gitmodules.zig");
    _ = @import("submodule/transport.zig");
    _ = @import("transport/bundle.zig");
    _ = @import("wire/connection.zig");
    _ = @import("wire/fetch_pack.zig");
    _ = @import("wire/filter_spec.zig");
    _ = @import("wire/http_settings.zig");
    _ = @import("codec/pkt_line.zig");
    _ = @import("wire/protocol.zig");
    _ = @import("wire/refspec.zig");
    _ = @import("wire/remote.zig");
    _ = @import("wire/send_pack.zig");
    _ = @import("wire/side_band.zig");
    _ = @import("wire/smart_http.zig");
    _ = @import("wire/ssh.zig");
    _ = @import("transport/upload_pack.zig");
    _ = @import("transport/receive_pack.zig");
    _ = @import("transport/http_backend.zig");
    _ = @import("lfs/server.zig");
    _ = @import("text/unicode_width.zig");
    _ = @import("checkout/convert.zig");
    _ = @import("checkout/dir_scan.zig");
    _ = @import("checkout/precompose_test.zig");
    _ = @import("names/path.zig");
    _ = @import("worktree/sparse_checkout.zig");
    _ = @import("diff/user_diff.zig");
    _ = @import("lfs/custom.zig");
    _ = @import("merge/octopus.zig");
    _ = @import("transport/remote_helper.zig");
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
    _ = @import("testing/object_corpus.zig");
}
