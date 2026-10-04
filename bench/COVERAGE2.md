# Coverage 2 inventory and equivalence

Every row uses both pinned relic builds and Git; gix 0.87.1, libgit2 1.9.7
through git2 0.21.0 and go-git 5.19.2 join where their API offers the work.
Fixtures have smoke/small/medium/large sizes from `mkops.py`.

| Public operation → workloads | What each available side does; equivalence |
|---|---|
| reftable read → `reftable-read` | List every ref and target; compare digest and complete refs. |
| reftable write → `reftable-write` | Create 10/1,000 refs in one transaction, no logs/fsync; compare complete refs. |
| reftable compaction → `reftable-compact` | Merge the same stack into one table; compare every ref and table count. |
| MIDX read → `midx-read` | Read every object body through a four-pack MIDX; compare count and body digest to git. |
| rerere record → `rerere-record` | Save manually resolved files with preimages present; compare rr-cache, MERGE_RR, index and files. |
| rerere replay → `rerere-replay` | Apply cached resolutions without staging; compare rr-cache, MERGE_RR, index and files. |
| sparse cone → `sparse-cone-set`, `sparse-cone-reapply` | Set d00, or remove a restored excluded file; compare patterns, flags, settings and all file bytes. |
| sparse non-cone → `sparse-noncone-set`, `sparse-noncone-reapply` | Set d00/side minus s00, or remove a restored excluded file; same checks. |
| shallow clone → `clone-depth` | Bare main only, depth 3, no tags/checkout; compare refs, boundary, graph and stored objects. |
| partial clone → `clone-blob-none`, `clone-tree-zero` | Bare main only, same filter, no tags/checkout; compare refs, promised graph and stored objects. |
| lazy fetch → `lazy-fetch` | Read one missing blob from the same partial clone; compare blob bytes, refs and stored objects. |
| upload-pack → `serve-full`, `serve-depth`, `serve-blob-none`, `serve-tree-zero` | Git v0 client clones from relic, git and go-git servers; compare refs, boundary, promised graph and stored objects. |
| LFS transfer → `lfs-upload`, `lfs-download` | Upload explicit object IDs with verification; fetch data tip's pointers; compare server journal and SHA-256 of every object. |
| LFS locks → `lfs-lock`, `lfs-unlock`, `lfs-lock-list`, `lfs-lock-verify` | Acquire/release/list/verify the same lock and caches; compare remote state and counts. |

MIDX writes: unavailable in relic (README: read only); no invented writer.
gix/libgit2 join MIDX reads; go-git lacks a MIDX reader.
gix/libgit2/go-git join depth clones; all lack partial-clone/lazy-fetch APIs.
gix/libgit2/go-git lack reftable backends, rerere, sparse set/reapply and LFS clients.
gix/libgit2 lack upload-pack servers; go-git serves full clones, without depth/filters.
Git's LFS rows use installed git-lfs; its version is recorded in reports.
Both pins fail cone/non-cone reapply of a vivified excluded file: it stays
present; Git removes it. A preflight records unavailable until a pin agrees.
Pure constants, option/result types, destructors and tiny getters are skipped:
they are setup/value helpers, not independent workloads.

No timed pass or performance claims: existing equivalence settings retained;
new rows compare outputs before numbers count. All servers bind 127.0.0.1.
Smoke/check results, final commit and head are supplied in the completion report.
Planning quiet duration for the complete harness: 110–180 minutes (shared Mac).
