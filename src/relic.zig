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
//! | `odb` | `Odb`: loose objects, packs, alternates. | `pack`, `delta`, `inflate`, `indexpack`, `revindex`, `commitgraph`, `midx`, `bitmap`, `accelerators`, `abbrev` |
//! | `refs` | `Store`, `Transaction`: loose refs and `packed-refs`, listed, sorted and formatted. | `reflog`, `reftable`, `reftablestack`, `filter` |
//! | `config` | `Config`: git's configuration files, lossless. | `userconfig` |
//! | `index` | `Index`: the `DIRC` file, versions 2 to 4. | `sparseindex` |
//! | `worktree` | Staging, writing a tree, checking one out, status. | `snapshot`, `worktrees`, `sparse`, `sparsecheckout`, `ignore`, `attributes`, `convert`, `filter`, `dirscan`, `safepath` |
//! | `diff` | Tree against tree, blob against blob, unified text. | `textdiff`, `rename`, `similarity`, `patchid`, `blame` |
//! | `revwalk` | Walking history, merge bases. | `revparse`, `shallow`, `mailmap`, `shortlog`, `describe`, `bisect` |
//! | `merge` | Three-way merges of contents and trees. | `blobmerge`, `ort`, `octopus`, `strategy`, `subtreeshift`, `threeway`, `rerere` |
//! | `commit` | Making a commit as `git commit` does. | `message`, `head`, `reset`, `stash`, `signing`, `commithooks`, `merging`, `sequencer`, `rebase`, `todo`, `notes` |
//! | `transport` | `Session`: a remote, open. | `remote`, `url`, `refspec`, `fetch`, `fetchpack`, `clone`, `push`, `sendpack`, `local`, `ssh`, `smarthttp`, `httpclient`, `tls`, `clientcert`, `httpauth`, `httpsettings`, `credential`, `auth`, `protocol`, `connection`, `pktline`, `sideband`, `uploadpack`, `objectwalk`, `objectfilter`, `partial`, `filterspec`, `progress`, `bundle`, `remotehelper` |
//! | `submodule` | Submodules: status, init, update, sync, absorb. | `gitmodules`, `gitlink`, `submoduletransport` |
//! | `lfs` | Git LFS in process: pointers and the store. | `lfsapi`, `lfstransfer`, `lfslocks`, `lfspush`, `lfshooks`, `lfsssh`, `lfscustom`, `netrc` |
//! | `patch` | Patches: read, applied, written from commits, applied from a mailbox, two series compared. | `apply`, `format`, `mail`, `am`, `rangediff` |
//! | `grep` | `git grep` over the working tree, the index or a tree. | |
//! | `archive` | `git archive`: a tree as a tar or zip file. | |
//! | `clean` | `git clean`: the untracked files of the working tree removed. | |
//! | `fastimport` | `git fast-import`: a fast-import stream read into a repository. | |
//! | `fastexport` | `git fast-export`: history written as a fast-import stream. | |
//!
//! | Shared plumbing | Used by |
//! |---|---|
//! | `unicodewidth` | `revwalk.shortlog` and `patch.format`: git's character and string columns. |

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
pub const fastimport = @import("fastimport.zig");
pub const fastexport = @import("fastexport.zig");
