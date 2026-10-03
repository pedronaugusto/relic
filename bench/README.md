# relic benchmark preparation

Keep the `bench` worktree in the workspace’s `.bench/relic`, outside `.zig-cache`; `bench/quiet.sh` resolves its files from its own directory.

Pinned before: `86045db483496f695795ec5ee653e99ebf2dd395`.
Pinned current fixture: `8f0962d2462adea17a339cc2866a70c8295bb906`.

`bench/quiet.sh` is the complete pass. `bench/quiet.sh --smoke` exercises
all available workloads once on tiny fixtures, without warmups or saved timing
values. Smoke is a correctness check, and never evidence for speed. Both
modes write plain Markdown and JSON to `bench/results/<local-date>/`; generated
results and build products are ignored. Smoke writes `smoke.md` / `smoke.json`
and its preparation step `prepare.md` / `prepare.json`; `--check-prepared`
writes `check.md` / `check.json`. Only the quiet pass writes `report.md` /
`report.json`, so neither smoke nor a check can overwrite a real pass. Use
`--output <directory>` for a separate run on the same day.

The full pass warms each workload, then repeats A (before), B (after), and the
comparison tools five times. `--runs N` changes the repetition count. Setup,
fixture generation and compilation happen before the measured work. Both
package builds use the same harness, toolchain and workloads. Compilation uses
ReleaseFast. Sources come from `git archive` of the pinned revisions, independent
of the working checkout or later main changes. `--before <revision>` and
`--after <revision>` explicitly override the pins in `revisions.json`.

The cutoff is `2026-09-30T00:00:00+01:00` (Lisbon). Use an explicit midnight:
Git's date-only `--before=2026-09-30` retains a time of day. Reports record the
full package revisions, harness revision, machine model, OS, CPU, memory and
tool versions, without a hostname or personal paths. Keep the raw samples;
these are warm-cache measurements, with no cold-disk or universal speed claim.

`PYTHON` overrides the interpreter. With it unset, the wrapper prefers an
already installed Python 3.13 found by `uv`, then falls back to `python3`; it
installs no interpreter. This avoids the host's Python 3.14 ensurepip failure.
Requires installed Zig 0.16.0, Git, Rust/Cargo, Go and Python. Build dependencies
are pinned in the existing lockfiles. `--build-dir <directory>` changes the
scratch/build location. Run the full pass only in the owner's quiet window.

Harness history stays on `bench`; never merge this branch into main.

The complete pass includes status, staging/write-tree, history walk, packed
blob reads, pack writing and index read/write; all four former regression
measurement workloads; every public operation below, at three sizes; HTTP
and local SSH-stand-in clone, clone with object checking, no-op fetch, fetch
with new objects and push; and pack-entry inflation with relic, Zig flate
(whole and chunked) and system zlib.

Comparison tools, on every workload: installed Git, gix 0.87.1, git2/libgit2
0.21.0 and go-git 5.19.2; Zig flate and system zlib for inflation. gix gains
its blocking network client over the system libcurl for clone and fetch. An
operation a tool does not have is an unavailable row with the reason, never
a hand-built stand-in. Git subprocess timings include startup; the library
timings begin inside the process. They answer different integration choices
and are labelled accordingly.

## Operations

`src/mkops.py` builds one repository family per size, seeded and with fixed
identities and dates: small (200 files, 100 commits), medium (3,000 files,
1,000 commits) and large (20,000 files, 300 commits), the transport sizes.
Each has `main`, a `side` branch of five commits that merges, rebases and
cherry-picks cleanly, a `conflict` branch with two conflicts, a `renamed`
branch moving 1 % of the files, a branch to switch to, 1,000 packed tags, a
bare copy whose branches are loose objects beside one pack, and a worktree
with 1 % of its files changed. LFS fixtures hold 20 files of 64 KiB, 1 MiB
and 16 MiB; the submodule fixture is ten local submodules, at one size.

| Operation | Workload |
|---|---|
| tree diff, rename detection, unified patch, index against worktree | `diff-tree`, `diff-renames`, `diff-patch`, `diff-index` |
| log, log of one path, revision parsing, merge base, patch ids | `log`, `log-path`, `revparse`, `merge-base`, `patch-id` |
| in-core merge, clean and conflicting | `merge-tree-clean`, `merge-tree-conflict` |
| merge, rebase, cherry-pick, revert, commit, switch, stash | `merge-clean`, `merge-conflict`, `rebase`, `cherry-pick`, `revert`, `commit`, `switch`, `stash` |
| branches, annotated tags, ref listing | `branch-create` (1,000 in one batch), `tag-create` (100), `ref-list` |
| repack, pack verification, linked worktree | `repack`, `verify`, `worktree-add` |
| LFS staging and checkout | `lfs-add`, `lfs-checkout` |
| submodules | `submodule-status`, `submodule-update` |
| working-tree snapshot | `snapshot` (Git: `git stash create`) |

A workload that only reads runs on the fixture, best of three repetitions
inside the process; one that writes runs once on a fresh APFS copy with its
index refreshed. Every side that does the work must agree on the result:
change, commit and ref counts, merge bases, trees, commit and tag object
names (every side commits with the same identity and clock), patch ids. Git
then checks what a write left: `HEAD`'s tree, a clean status, the conflicted
paths, the stash list, the refs, a repack's single pack holding every
reachable object, LFS pointers rather than contents in the index and
contents rather than pointers in the working tree, submodules at their
recorded commits. A revision that lacks an operation reports it unavailable;
the pinned before has no working-tree snapshots.

Each write starts from a fresh copy of the same fixture, with index refresh
and mutation outside timing. Every transport output is checked against the
expected remote tip and with `git fsck --strict`; a push is checked on the
receiving repository, a copy of the base made per sample with
`http.receivepack` on. The server is bound to
loopback and is stopped on exit. Network timings are local protocol costs.
The full transport uses the existing small, medium and large fixture shapes.

Compatibility adapters consume errors from refreshed worktree rules, borrow
object format and the ref store through the final repository API, and pass
`writeTag`'s diagnostic only where it takes one. The regression
harness uses the current source implementation, including its declared
Conduit dependency. Its smoke sizes are 30 staged files, three history rounds
and 1 KiB hashed; full sizes retain the existing 3,000 files and 64 MiB.
Speed conditions are reported in a quiet pass; deterministic result checks
still fail on wrong counts, hashes, trees, or pack contents.

Quiet-only planning estimate: **60–100 minutes**. See [QUIET-PREP.md](QUIET-PREP.md) for preparation, counts, sizes and assumptions. `run.sh` and `transport/run.sh` remain
low-level helpers; use `quiet.sh` for the complete interleaved pass.

Standalone `zig build -Doptimize=Debug` compiles the pinned after harness
without running it. Snapshot builds pass `-Dsnapshot=true` to compile the
archived local revision instead; quiet runs retain ReleaseFast.
