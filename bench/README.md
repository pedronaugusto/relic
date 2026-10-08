# relic's benchmarks

relic's own measurements of its own work, against nothing else. They are timed on
a quiet machine. CI compiles them and runs untimed smoke checks.

```sh
zig build bench -Doptimize=ReleaseFast
./zig-out/bench/relic-regressions
```

Select one row after building with `./zig-out/bench/relic-regressions "smart HTTP"`.

`relic-regressions` builds its repositories with the `git` on the path, in
temporary directories, and prints each measurement with the condition it is
held to:

- staging 3,000 files over 60 directories with `add -A`, cold and warm,
  `write-tree` and `status`, and how many files each pass hashed;
- reading every object of a pack with delta chains, cold and warm;
- SHA-1 against the standard library's, with collision detection, and
  SHA-256, in GiB/s;
- staging into loose objects against staging into a pack, and writing a
  pack whole and deltified: objects per second, MiB/s and the bytes the
  deltas save;
- ignore rules over four levels and attribute rules deciding 100,000 paths,
  and what reading the rules costs;
- `status` over a tree with an ignore file in every directory;
- `for-each-ref` choosing among 20,000 packed refs by pattern;
- unified bodies, line counts and content merges of 400 files, and a blame
  through 200 commits;
- smart HTTP on loopback over one kept connection, against a server that
  answers from memory: a 256 MiB answer read through its pkt-lines, and
  small exchanges per second.
  LFS downloads also time a 256 MiB object through SHA-256 and its store.

A Debug build measures a smaller tree with the same ratios. `relic-regressions --smoke`
runs every measurement once on a tiny tree without reading a clock, to check
that each still works.

`relic-native` measures cached 256-byte native pipe round trips through
Shakedown, with process startup outside the clock and exact answer checking.
`relic-native --smoke` runs the protocol without sampling timings.

`relic-local-push` uses shakedown.bench for a repeated local push of one commit,
one tree and one blob, including pack writing and receiver ref publication.
Construction and teardown are outside timing. `--smoke` checks its object count,
accepted report and final ref without reporting timing. Compare ReleaseFast
executables in paired, interleaved order; fixture filesystem work remains visible
in the timing spread.

`relic-ere` measures boolean and span compile/search adapters on one bounded
interval expression through shakedown.bench. It checks the boolean result and
exact longest span on every operation; `--smoke` checks both without timing.
