# relic benchmark preparation

Keep the `bench` worktree in the workspace’s `.bench/relic`, outside `.zig-cache`; `bench/quiet.sh` resolves its files from its own directory.

Pinned before: `86045db483496f695795ec5ee653e99ebf2dd395`.
Pinned current perf: `e73636117a9a9fe04d84ef9845a3eb83268cc0b2`.

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
measurement workloads; HTTP and local SSH-stand-in clone, clone with object
checking, no-op fetch and fetch with new objects; and pack-entry inflation
with relic, Zig flate (whole and chunked) and system zlib.

Same-job tools retained: installed Git, gix 0.87.1, git2/libgit2 0.21.0,
go-git 5.19.2, Zig flate and system zlib. Unsupported tool operations remain
explicit unavailable rows. Git subprocess timings include startup; the
library timings begin inside the process. They answer different integration
choices and are labelled accordingly. No additional tool was added.

Each write starts from a fresh copy of the same fixture, with index refresh
and mutation outside timing. Every transport output is checked against the
expected remote tip and with `git fsck --strict`. The server is bound to
loopback and is stopped on exit. Network timings are local protocol costs.
The full transport uses the existing small, medium and large fixture shapes.

Compatibility adapters consume errors from refreshed worktree rules and
borrow object format through the final repository API. The regression
harness uses the current source implementation, including its declared
Conduit dependency. Its smoke sizes are 30 staged files, three history rounds
and 1 KiB hashed; full sizes retain the existing 3,000 files and 64 MiB.
Speed conditions are reported in a quiet pass; deterministic result checks
still fail on wrong counts, hashes, trees, or pack contents.

Quiet-only planning estimate: **8–20 minutes**. See [QUIET-PREP.md](QUIET-PREP.md) for preparation, counts, sizes and assumptions. `run.sh` and `transport/run.sh` remain
low-level helpers; use `quiet.sh` for the complete interleaved pass.

Standalone `zig build -Doptimize=Debug` compiles the pinned after harness
without running it. Snapshot builds pass `-Dsnapshot=true` to compile the
archived local revision instead; quiet runs retain ReleaseFast.
