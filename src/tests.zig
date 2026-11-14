//! The core's tests: the root of the test binary that holds the core's files
//! and their tests, and relic's public root compiled among them. A helper
//! the LFS tests share reaches the core as `relic_core`, which here is this
//! file: it has every name of `core.zig`, as `core.zig` has it.
const core = @import("core.zig");

pub const repo = core.repo;
pub const hash = core.hash;
pub const object = core.object;
pub const odb = core.odb;
pub const refs = core.refs;
pub const config = core.config;
pub const index = core.index;
pub const worktree = core.worktree;
pub const diff = core.diff;
pub const rev_walk = core.rev_walk;
pub const merge = core.merge;
pub const commit = core.commit;
pub const transport = core.transport;
pub const submodule = core.submodule;
pub const patch = core.patch;
pub const grep = core.grep;
pub const archive = core.archive;
pub const pretty = core.pretty;
pub const clean = core.clean;
pub const fast = core.fast;
pub const maintenance = core.maintenance;
pub const checkout = core.checkout;
pub const codec = core.codec;
pub const discover = core.discover;
pub const fs = core.fs;
pub const hooks = core.hooks;
pub const mail = core.mail;
pub const names = core.names;
pub const patterns = core.patterns;
pub const process = core.process;
pub const report = core.report;
pub const stage = core.stage;
pub const text = core.text;
pub const walk = core.walk;
pub const wire = core.wire;
pub const http_backend = core.http_backend;
pub const contract = core.contract;

comptime {
    for (@typeInfo(core).@"struct".decl_names) |name| if (!@hasDecl(@This(), name)) @compileError("src/tests.zig lacks core's `" ++ name ++ "`");
    for (@typeInfo(@This()).@"struct".decl_names) |name| if (!@hasDecl(core, name)) @compileError("src/tests.zig's `" ++ name ++ "` is not core's");
}
const std = @import("std");
const builtin = @import("builtin");
const features = @import("relic_options");
const relic = @import("relic.zig");

test "the plumbing is relic's own: no public name reaches it" {
    try std.testing.expect(!@hasDecl(odb, "varint"));
    try std.testing.expect(!@hasDecl(index, "ewah"));
    try std.testing.expect(!@hasDecl(rev_walk, "ere"));
    try std.testing.expect(!@hasDecl(worktree, "platstat"));
    try std.testing.expect(!@hasDecl(transport, "httpclient"));
    try std.testing.expect(!@hasDecl(transport, "httpauth"));
    try std.testing.expect(!@hasDecl(transport, "tls"));
    try std.testing.expect(!@hasDecl(transport, "client_cert"));
}

// relic_lfs's tests, where it is built.
test {
    if (features.lfs) _ = @import("lfs_tests.zig");
}

test {
    _ = @import("testing/policy_options.zig");
    // Every module the API reaches, one level down as well as at the top,
    // so that every file under the root is compiled and its tests run.
    std.testing.refAllDecls(relic);
    inline for (@typeInfo(relic).@"struct".decl_names) |name| {
        if (@TypeOf(@field(relic, name)) == type) std.testing.refAllDecls(@field(relic, name));
    }
    if (builtin.is_test) {
        // the plumbing the API keeps to itself: reached by no public name,
        // so named here for its tests to run
        _ = @import("codec/varint.zig");
        _ = @import("codec/rows.zig");
        _ = @import("odb/keep.zig");
        _ = @import("odb/quarantine.zig");
        _ = @import("maintenance/server_info.zig");
        _ = @import("walk/walk.zig");
        _ = @import("wire/credential/store.zig");
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
        _ = @import("config/write.zig");
        _ = @import("testing/git.zig");
        _ = @import("testing/git_release.zig");
        _ = @import("testing/helpers.zig");
        _ = @import("testing/fixtures.zig");
        _ = @import("maintenance/maintenance_test.zig");
        _ = @import("maintenance/gc_test.zig");
        _ = @import("maintenance/prune_test.zig");
        _ = @import("maintenance/repack_test.zig");
        _ = @import("maintenance/collect_test.zig");
        _ = @import("maintenance/run_test.zig");
        _ = @import("stage/remove.zig");
        _ = @import("stage/remove_test.zig");
        _ = @import("stage/move.zig");
        _ = @import("stage/move_test.zig");
        _ = @import("checkout/checkout_test.zig");
        _ = @import("checkout/worktrees_test.zig");
        _ = @import("repo/repo_test.zig");
        _ = @import("testing/concurrency.zig");
        _ = @import("testing/cancel.zig");
        _ = @import("testing/cancel_history.zig");
        _ = @import("testing/work_count.zig");
        _ = @import("testing/pack_write.zig");
        // each parser's documented guarantees, as properties
        _ = @import("codec/guarantees_test.zig");
        _ = @import("config/guarantees_test.zig");
        _ = @import("index/guarantees_test.zig");
        _ = @import("object/guarantees_test.zig");
        _ = @import("odb/guarantees_test.zig");
        _ = @import("wire/guarantees_test.zig");
        _ = @import("diff/diff_test.zig");
        _ = @import("diff/blame_test.zig");
        _ = @import("diff/blame/ignore.zig");
        _ = @import("submodule/submodule_test.zig");
        _ = @import("submodule/move_test.zig");
        _ = @import("submodule/diff_test.zig");
        _ = @import("submodule/branch_test.zig");
        _ = @import("checkout/filter_test.zig");
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
        _ = @import("wire/auth_test.zig");
        _ = @import("walk/walk_test.zig");
        _ = @import("walk/shallow_test.zig");
        _ = @import("transport/partial_test.zig");
        _ = @import("testing/history.zig");
        _ = @import("testing/autostash.zig");
        _ = @import("testing/pull.zig");
        _ = @import("testing/replay.zig");
        _ = @import("testing/history_command.zig");
        _ = @import("testing/last_modified.zig");
        _ = @import("testing/backfill.zig");
        _ = @import("testing/rebase_merges.zig");
        _ = @import("testing/rebase_settings.zig");
        _ = @import("testing/rebase_apply.zig");
        _ = @import("testing/branch.zig");
        _ = @import("testing/follow.zig");
        _ = @import("testing/textconv.zig");
        _ = @import("testing/hunk_headers.zig");
        _ = @import("testing/word_diff.zig");
        _ = @import("testing/combined_diff.zig");
        _ = @import("testing/commit_diff.zig");
        _ = @import("testing/big_files.zig");
        _ = @import("testing/canceled_scans.zig");
        _ = @import("testing/every_cancel.zig");
        _ = @import("testing/canceled_text.zig");
        _ = @import("testing/streamed_objects.zig");
        _ = @import("testing/object_stream.zig");
        _ = @import("testing/external_diff.zig");
        _ = @import("testing/diff_prefixes.zig");
        _ = @import("testing/diff_cached.zig");
        _ = @import("testing/replace_refs.zig");
        _ = @import("testing/packfile_uris.zig");
        _ = @import("testing/dumb_http.zig");
        _ = @import("testing/git_daemon.zig");
        _ = @import("testing/diff_stat.zig");
        _ = @import("commit/commit.zig");
        _ = @import("merge/merge.zig");
        _ = @import("patch/patch.zig");
        _ = @import("refs/refs.zig");
        _ = @import("refs/reftable/table.zig");
        _ = @import("testing/log_formats.zig");
        _ = @import("merge/ort_test.zig");
        _ = @import("transport/upload_pack_test.zig");
        _ = @import("transport/receive_pack_test.zig");
        // relic's HTTP server, uplink's: there only with `http`.
        if (features.http) _ = @import("transport/http_backend_test.zig");
        _ = @import("testing/clone_config.zig");
        _ = @import("wire/client_cert_test.zig");
        _ = @import("wire/pinned_key.zig");
        _ = @import("merge/strategy_test.zig");
        _ = @import("transport/bundle_test.zig");
        _ = @import("transport/bundle/uri_test.zig");
        _ = @import("patch/apply_test.zig");
        _ = @import("patch/format_test.zig");
        _ = @import("patch/am_test.zig");
        _ = @import("repo/in_progress_test.zig");
        _ = @import("grep_test.zig");
        _ = @import("archive/archive_test.zig");
        _ = @import("archive/remote_test.zig");
        _ = @import("clean_test.zig");
        _ = @import("fast/importer_test.zig");
        _ = @import("fast/exporter_test.zig");
        _ = @import("transport/remote_helper_test.zig");
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
        _ = @import("wire/credential/cache.zig");
        _ = @import("testing/shared.zig");
        _ = @import("repo/ident_test.zig");
    }
}

test {
    _ = @import("odb/rev_index_test.zig");
    _ = @import("index/sparse_index_test.zig");
    _ = @import("index/untracked.zig");
    _ = @import("index/untracked_test.zig");
    _ = @import("index/split_test.zig");
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
    _ = @import("rebase/rebase.zig");
    _ = @import("commit/sequencer.zig");
    _ = @import("commit/stash.zig");
    _ = @import("config/user_config.zig");
    _ = @import("fast/exporter.zig");
    _ = @import("fast/importer.zig");
    _ = @import("grep.zig");
    _ = @import("hash/sha1dc.zig");
    _ = @import("merge/rerere.zig");
    _ = @import("merge/three_way.zig");
    _ = @import("odb/bitmap.zig");
    _ = @import("odb/mtimes.zig");
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
    _ = @import("repo/rev_parse_test.zig");
    _ = @import("walk/shallow.zig");
    _ = @import("pretty/shortlog.zig");
    _ = @import("discover/gitlink.zig");
    _ = @import("config/gitmodules.zig");
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
    _ = @import("transport/alternate_refs.zig");
    _ = @import("archive/archive.zig");
    _ = @import("archive/remote.zig");
    _ = @import("transport/http_backend.zig");
    _ = @import("text/unicode_width.zig");
    _ = @import("checkout/convert.zig");
    _ = @import("checkout/dir_scan.zig");
    _ = @import("checkout/precompose_test.zig");
    _ = @import("names/path.zig");
    _ = @import("worktree/sparse_checkout.zig");
    _ = @import("diff/driver.zig");
    _ = @import("diff/words.zig");
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
    _ = @import("testing/security/tree_paths.zig");
}

test {}

test {}

test {
    _ = @import("testing/codec_object.zig");
    _ = @import("testing/object_corpus.zig");
}
