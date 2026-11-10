//! relic — read and write a git repository from Zig.
//!
//! The table below describes the exported namespaces; it is checked against
//! the API, and the README's against both, wherever relic compiles.
//!
//! | Module | Purpose |
//! |---|---|
//! | `repo` | Public concern. |
//! | `repo.warning` | Module within `repo`. |
//! | `repo.hooks` | Module within `repo`. |
//! | `repo.program` | Module within `repo`. |
//! | `repo.fs` | Module within `repo`. |
//! | `repo.safe` | Module within `repo`. |
//! | `repo.ident` | Module within `repo`. |
//! | `repo.state` | The state files an operation keeps in the git directory: written, read and removed in one place. |
//! | `repo.rev_parse` | Module within `repo`. |
//! | `hash` | Public concern. |
//! | `hash.sha1` | Module within `hash`. |
//! | `hash.sha1dc` | Module within `hash`. |
//! | `object` | Public concern. |
//! | `object.fsck` | Module within `object`. |
//! | `odb` | Public concern. |
//! | `odb.abbrev` | Module within `odb`. |
//! | `odb.bitmap` | Module within `odb`. |
//! | `odb.commit_graph` | Module within `odb`. |
//! | `odb.commit_graph.bloom` | Module within `odb.commit_graph`. |
//! | `odb.rev_index` | Module within `odb`. |
//! | `odb.mtimes` | Module within `odb`. |
//! | `odb.islands` | Delta islands, the pack writer's side: which islands each object is in, and whether one may be a delta of another. |
//! | `odb.index_pack` | Module within `odb`. |
//! | `odb.pack` | Module within `odb`. |
//! | `odb.delta` | Module within `odb`. |
//! | `odb.midx` | Module within `odb`. |
//! | `odb.quarantine` | Module within `odb`. |
//! | `refs` | Public concern. |
//! | `refs.reftable` | Module within `refs`. |
//! | `refs.reftable.table` | The reftable format: one table read and written. |
//! | `refs.reftable.stack` | The stack of tables `tables.list` names: the ref store. |
//! | `refs.verify` | git's `refs verify`: what is wrong with the refs themselves, by `fsck.<msg-id>`. |
//! | `refs.names` | Module within `refs`. |
//! | `config` | Public concern. |
//! | `config.user` | Module within `config`. |
//! | `config.color` | git's colours: values, `color.ui` and the writers' settings and slots. |
//! | `index` | Public concern. |
//! | `index.sparse` | Module within `index`. |
//! | `index.untracked` | The untracked cache, git's `UNTR`: read, kept true as entries come and go, and written. |
//! | `worktree` | Public concern. |
//! | `worktree.sparse_checkout` | Module within `worktree`. |
//! | `worktree.linked` | Module within `worktree`. |
//! | `worktree.snapshot` | Module within `worktree`. |
//! | `worktree.renames` | Module within `worktree`. |
//! | `worktree.remove` | `git rm`: the index entries a pathspec names removed, and their files and submodules, after git's check for what the removal would lose. |
//! | `worktree.move` | `git mv`: files, directories and submodules renamed in the working tree and the index together, after git's checks of every source. |
//! | `worktree.sparse` | Module within `worktree`. |
//! | `worktree.ignore` | Module within `worktree`. |
//! | `worktree.attributes` | Module within `worktree`. |
//! | `worktree.convert` | Module within `worktree`. |
//! | `worktree.encoding` | Module within `worktree`. |
//! | `worktree.fsmonitor` | Module within `worktree`. |
//! | `worktree.filter` | Module within `worktree`. |
//! | `worktree.filter.native` | Native content-filter protocol. |
//! | `worktree.dir_scan` | Module within `worktree`. |
//! | `worktree.safe_path` | Module within `worktree`. |
//! | `diff` | Public concern. |
//! | `diff.blame` | Module within `diff`. |
//! | `diff.combined` | Module within `diff`. |
//! | `diff.driver` | Module within `diff`. |
//! | `diff.external` | Module within `diff`. |
//! | `diff.patch_id` | Module within `diff`. |
//! | `diff.rename` | Module within `diff`. |
//! | `diff.similarity` | Module within `diff`. |
//! | `diff.stat` | Module within `diff`. |
//! | `diff.textconv` | Module within `diff`. |
//! | `rev_walk` | Public concern. |
//! | `rev_walk.bisect` | Module within `rev_walk`. |
//! | `rev_walk.describe` | Module within `rev_walk`. |
//! | `rev_walk.fork_point` | Module within `rev_walk`. |
//! | `rev_walk.follow` | Module within `rev_walk`. |
//! | `rev_walk.last_modified` | Module within `rev_walk`. |
//! | `rev_walk.path_walk` | Module within `rev_walk`. |
//! | `rev_walk.mailmap` | Module within `rev_walk`. |
//! | `rev_walk.shallow` | Module within `rev_walk`. |
//! | `rev_walk.object` | Module within `rev_walk`. |
//! | `rev_walk.object.walk` | Module within `rev_walk.object`. |
//! | `rev_walk.object.filter` | Module within `rev_walk.object`. |
//! | `merge` | Public concern. |
//! | `merge.rerere` | Module within `merge`. |
//! | `merge.three_way` | Module within `merge`. |
//! | `merge.subtree_shift` | Module within `merge`. |
//! | `merge.strategy` | Module within `merge`. |
//! | `merge.ort` | Module within `merge`. |
//! | `merge.octopus` | Module within `merge`. |
//! | `commit` | Public concern. |
//! | `commit.notes` | Module within `commit`. |
//! | `commit.todo` | Module within `commit`. |
//! | `commit.branch` | Module within `commit`. |
//! | `commit.rebase` | Module within `commit`. |
//! | `commit.replay` | Module within `commit`. |
//! | `commit.history` | Module within `commit`. |
//! | `commit.sequencer` | Module within `commit`. |
//! | `commit.merging` | Module within `commit`. |
//! | `commit.stash` | Module within `commit`. |
//! | `commit.in_progress` | `read`: which operations a worktree is in the middle of, as `git status` says. |
//! | `commit.message` | Module within `commit`. |
//! | `commit.trailer` | Module within `commit`. |
//! | `commit.head` | Module within `commit`. |
//! | `commit.reset` | Module within `commit`. |
//! | `commit.signing` | Module within `commit`. |
//! | `commit.hooks` | Module within `commit`. |
//! | `transport` | Public concern. |
//! | `transport.filter_spec` | Module within `transport`. |
//! | `transport.partial` | Module within `transport`. |
//! | `transport.side_band` | Module within `transport`. |
//! | `transport.http_settings` | Module within `transport`. |
//! | `transport.hidden` | Module within `transport`. |
//! | `transport.promisors` | Module within `transport`. |
//! | `transport.push` | Module within `transport`. |
//! | `transport.clone` | Module within `transport`. |
//! | `transport.fetch` | Module within `transport`. |
//! | `transport.pull` | Module within `transport`. |
//! | `transport.backfill` | Module within `transport`. |
//! | `transport.refspec` | Module within `transport`. |
//! | `transport.remote` | Module within `transport`. |
//! | `transport.url` | Module within `transport`. |
//! | `transport.fetch_pack` | Module within `transport`. |
//! | `transport.send_pack` | Module within `transport`. |
//! | `transport.local` | Module within `transport`. |
//! | `transport.ssh` | Module within `transport`. |
//! | `transport.smart_http` | Module within `transport`. |
//! | `transport.credential` | Module within `transport`. |
//! | `transport.credential.cache` | git's `credential-cache` client. |
//! | `transport.credential_cache_daemon` | Module within `transport`. |
//! | `transport.auth` | Module within `transport`. |
//! | `transport.protocol` | Module within `transport`. |
//! | `transport.connection` | Module within `transport`. |
//! | `transport.pkt_line` | Module within `transport`. |
//! | `transport.upload_pack` | Module within `transport`. |
//! | `transport.receive_pack` | Module within `transport`. |
//! | `transport.http_backend` | Module within `transport`. Only with `http`. |
//! | `transport.bundle` | Module within `transport`. |
//! | `transport.bundle_uri` | Module within `transport`. |
//! | `transport.progress` | Module within `transport`. |
//! | `transport.remote_helper` | Module within `transport`. |
//! | `transport.policy` | Module within `transport`. |
//! | `submodule` | Public concern. |
//! | `submodule.gitmodules` | Module within `submodule`. |
//! | `submodule.gitlink` | Module within `submodule`. |
//! | `patch` | Public concern. |
//! | `patch.am` | Module within `patch`. |
//! | `patch.commit_diff` | Module within `patch`. |
//! | `patch.mail` | Module within `patch`. |
//! | `patch.format` | Module within `patch`. |
//! | `patch.apply` | Module within `patch`. |
//! | `patch.range_diff` | Module within `patch`. |
//! | `grep` | Public concern. |
//! | `archive` | Public concern. |
//! | `archive.remote` | Module within `archive`. |
//! | `pretty` | Public concern. |
//! | `pretty.log` | Module within `pretty`. |
//! | `pretty.refs` | Module within `pretty`. |
//! | `pretty.shortlog` | Module within `pretty`. |
//! | `clean` | Public concern. |
//! | `fast` | Public concern. |
//! | `fast.importer` | Module within `fast`. |
//! | `fast.exporter` | Module within `fast`. |
//! | `maintenance` | Public concern. |

const core = @import("relic_core");

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
pub const transport = if (features.http) transport_with_http else core.transport;
pub const submodule = core.submodule;
pub const patch = core.patch;
pub const grep = core.grep;
pub const archive = core.archive;
pub const pretty = core.pretty;
pub const clean = core.clean;
pub const fast = core.fast;

pub const maintenance = core.maintenance;

/// The features this build has: `http` (uplink and cloak) and `lfs` (strand).
const features = @import("relic_options");

/// Which optional features relic was built with.
pub const Features = struct {
    /// Fetching and pushing over HTTP(S), with uplink and cloak.
    http: bool,
    /// Git LFS's transfers, locks and agents, with strand: the `relic_lfs`
    /// module, which exists only with it.
    lfs: bool,
};

/// This build's features, as the dependency's `.http` and `.lfs` options set them.
pub const built_with: Features = .{ .http = features.http, .lfs = features.lfs };

// A declaration exists exactly when its types do: a namespace with a module
// only one feature holds is chosen whole, the name absent without it, so
// `@hasDecl` tells the truth and a consumer is told "no member" when it
// compiles. The choice lists every name of its namespace and the one it
// adds, which `sameNamesBut` holds to.
/// `transport` with `http`: every name of its namespace, and git's http-backend served on uplink's server.
const transport_with_http = struct {
    const base = core.transport;
    pub const filter_spec = base.filter_spec;
    pub const partial = base.partial;
    pub const side_band = base.side_band;
    pub const http_settings = base.http_settings;
    pub const hidden = base.hidden;
    pub const promisors = base.promisors;
    pub const push = base.push;
    pub const clone = base.clone;
    pub const fetch = base.fetch;
    pub const pull = base.pull;
    pub const backfill = base.backfill;
    pub const refspec = base.refspec;
    pub const remote = base.remote;
    pub const url = base.url;
    pub const fetch_pack = base.fetch_pack;
    pub const send_pack = base.send_pack;
    pub const local = base.local;
    pub const ssh = base.ssh;
    pub const smart_http = base.smart_http;
    pub const credential = base.credential;
    pub const credential_cache_daemon = base.credential_cache_daemon;
    pub const auth = base.auth;
    pub const protocol = base.protocol;
    pub const connection = base.connection;
    pub const pkt_line = base.pkt_line;
    pub const upload_pack = base.upload_pack;
    pub const receive_pack = base.receive_pack;
    pub const bundle = base.bundle;
    pub const bundle_uri = base.bundle_uri;
    pub const progress = base.progress;
    pub const remote_helper = base.remote_helper;
    pub const policy = base.policy;
    pub const Error = base.Error;
    pub const Options = base.Options;
    pub const wantsV2 = base.wantsV2;
    pub const Session = base.Session;
    pub const download = base.download;
    pub const http_backend = core.http_backend;
};

comptime {
    core.contract.sameNamesBut(core.transport, transport_with_http, "http_backend");
}

// The contract relic's public surface keeps (`core.contract`), checked as
// relic compiles, on any target, so that no build of it breaks one; and how
// a program ended is conduit's `Term` wherever relic shows it, and a
// program's working directory is relic's own `Cwd`.
comptime {
    core.contract.check(@This(), .{
        .source = @embedFile("relic.zig"),
        .path = "src/relic.zig",
        .readme = @embedFile("README.md"),
        .begin = "<!-- BEGIN MODULES -->",
        .end = "<!-- END MODULES -->",
        .depth = 3,
    });
    checkPrograms();
}

const conduit = @import("conduit");

/// How a program ended is conduit's `Term` wherever relic shows it, never
/// the standard library's, and a program's working directory is relic's
/// own `Cwd`.
fn checkPrograms() void {
    const program = repo.program;
    if (@FieldType(program.Invocation, "cwd") != program.Cwd or @FieldType(commit.trailer.Commands, "cwd") != program.Cwd)
        @compileError("a program's working directory is `repo.program.Cwd`");
    const terms = .{
        program.Term,
        @FieldType(program.Outcome, "term"),
        program.Child.Term,
        @typeInfo(@typeInfo(@TypeOf(program.Running.wait)).@"fn".return_type.?).error_union.payload,
        @typeInfo(@typeInfo(@TypeOf(program.Child.wait)).@"fn".return_type.?).error_union.payload,
        @typeInfo(@FieldType(repo.hooks.Failure, "term")).optional.child,
        @typeInfo(@FieldType(transport.connection.Process, "term")).optional.child,
    };
    inline for (terms) |term| if (term != conduit.Term) @compileError("how a program ended is `conduit.Term`");
}
