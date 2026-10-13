//! relic — read and write a git repository from Zig.
//!
//! The table below describes the exported namespaces; its contract is checked against
//! the API.
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
//! | `odb.index_pack` | Module within `odb`. |
//! | `odb.pack` | Module within `odb`. |
//! | `odb.delta` | Module within `odb`. |
//! | `odb.midx` | Module within `odb`. |
//! | `refs` | Public concern. |
//! | `refs.reftable` | Module within `refs`. |
//! | `refs.reftable.table` | The reftable format: one table read and written. |
//! | `refs.reftable.stack` | The stack of tables `tables.list` names: the ref store. |
//! | `refs.names` | Module within `refs`. |
//! | `config` | Public concern. |
//! | `config.user` | Module within `config`. |
//! | `index` | Public concern. |
//! | `index.sparse` | Module within `index`. |
//! | `worktree` | Public concern. |
//! | `worktree.sparse_checkout` | Module within `worktree`. |
//! | `worktree.linked` | Module within `worktree`. |
//! | `worktree.snapshot` | Module within `worktree`. |
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
//! | `diff.patch_id` | Module within `diff`. |
//! | `diff.rename` | Module within `diff`. |
//! | `diff.similarity` | Module within `diff`. |
//! | `rev_walk` | Public concern. |
//! | `rev_walk.bisect` | Module within `rev_walk`. |
//! | `rev_walk.describe` | Module within `rev_walk`. |
//! | `rev_walk.mailmap` | Module within `rev_walk`. |
//! | `rev_walk.rev_parse` | Module within `rev_walk`. |
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
//! | `commit.rebase` | Module within `commit`. |
//! | `commit.sequencer` | Module within `commit`. |
//! | `commit.merging` | Module within `commit`. |
//! | `commit.stash` | Module within `commit`. |
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
//! | `transport.refspec` | Module within `transport`. |
//! | `transport.remote` | Module within `transport`. |
//! | `transport.url` | Module within `transport`. |
//! | `transport.fetch_pack` | Module within `transport`. |
//! | `transport.send_pack` | Module within `transport`. |
//! | `transport.local` | Module within `transport`. |
//! | `transport.ssh` | Module within `transport`. |
//! | `transport.smart_http` | Module within `transport`. |
//! | `transport.credential` | Module within `transport`. |
//! | `transport.auth` | Module within `transport`. |
//! | `transport.protocol` | Module within `transport`. |
//! | `transport.connection` | Module within `transport`. |
//! | `transport.pkt_line` | Module within `transport`. |
//! | `transport.upload_pack` | Module within `transport`. |
//! | `transport.bundle` | Module within `transport`. |
//! | `transport.progress` | Module within `transport`. |
//! | `transport.remote_helper` | Module within `transport`. |
//! | `transport.policy` | Module within `transport`. |
//! | `submodule` | Public concern. |
//! | `submodule.transport` | Module within `submodule`. |
//! | `submodule.gitmodules` | Module within `submodule`. |
//! | `submodule.gitlink` | Module within `submodule`. |
//! | `lfs` | Public concern. |
//! | `lfs.filter` | Native LFS filters selected by an operation owner. |
//! | `lfs.clone` | Clone with native LFS checkout and downloads. |
//! | `lfs.netrc` | Module within `lfs`. |
//! | `lfs.ssh` | Module within `lfs`. |
//! | `lfs.hooks` | Module within `lfs`. |
//! | `lfs.push` | Module within `lfs`. |
//! | `lfs.locks` | Module within `lfs`. |
//! | `lfs.transfer` | Module within `lfs`. |
//! | `lfs.custom` | Module within `lfs`. |
//! | `lfs.api` | Module within `lfs`. |
//! | `patch` | Public concern. |
//! | `patch.am` | Module within `patch`. |
//! | `patch.mail` | Module within `patch`. |
//! | `patch.format` | Module within `patch`. |
//! | `patch.apply` | Module within `patch`. |
//! | `patch.range_diff` | Module within `patch`. |
//! | `grep` | Public concern. |
//! | `archive` | Public concern. |
//! | `pretty` | Public concern. |
//! | `pretty.refs` | Module within `pretty`. |
//! | `pretty.shortlog` | Module within `pretty`. |
//! | `clean` | Public concern. |
//! | `fast` | Public concern. |
//! | `fast.importer` | Module within `fast`. |
//! | `fast.exporter` | Module within `fast`. |
//! | `maintenance` | Public concern. |

pub const repo = @import("repo.zig");
pub const hash = @import("hash.zig");
pub const object = @import("object.zig");
pub const odb = @import("odb.zig");
pub const refs = @import("refs.zig");
pub const config = @import("config.zig");
pub const index = @import("index.zig");
pub const worktree = @import("worktree.zig");
pub const diff = @import("diff.zig");
pub const rev_walk = @import("rev_walk.zig");
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
pub const fast = @import("fast.zig");

pub const maintenance = @import("maintenance.zig");
