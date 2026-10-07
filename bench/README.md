# relic's benchmarks

relic's own measurements of its own work, against nothing else. They run on
a quiet machine and never in CI; CI only compiles them (`zig build check`).

```sh
zig build bench -Doptimize=ReleaseFast
./zig-out/bench/relic-regressions
```

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
  through 200 commits.

A Debug build measures a smaller tree with the same ratios. `-Dbench-smoke`
builds it to run every measurement once on a tiny tree without reading a
clock, to check that each still works.
