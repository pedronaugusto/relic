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

`relic-rows` is one program, so the library compiles once for all of its groups.
It times each through shakedown.bench and prints its rows as JSON lines;
`--smoke` runs every row once without a clock, and `--row PREFIX` runs the rows whose names start with it, as preflight's `bench-ab` passes it. The groups:

- rules: loading and matching a 32-line ignore file, an includeIf condition,
  loading an attributes file and looking one path up, and the CRC kernel over 1 MiB;
- patch: one git patch of 64 files and 512 hunks read whole, and checked against a working tree holding the 64 files, checking the files read;
- ere: boolean and span compile/search on one bounded interval expression,
  checking the boolean result and the exact longest span on every operation;
- pack codec: reused compression of 32 KiB text and noise at each pack level;
- zstd: the 128 KiB RLE-frame reader LFS uses, checking exact output and stream
  termination;
- local push: a repeated local push of one commit, one tree and one blob,
  including pack writing and receiver ref publication, with construction and
  teardown outside the timing and the object count, accepted report and final
  ref checked;
- native: cached 256-byte native pipe round trips, with process startup outside
  the clock and exact answer checking.

Compare ReleaseFast executables in paired, interleaved order (`zig build bench-ab`);
fixture filesystem work remains visible in the timing spread. Fixture and buffer
allocation stay outside the clock.
