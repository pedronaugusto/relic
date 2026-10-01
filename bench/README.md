# relic benchmarks

Compares status, staging/write-tree, history walk, blob reads, pack writing
and index read/write with Git, Rust gix/libgit2 (git2), and Go go-git.
Unsupported rival APIs report unavailable rows. `transport/` compares
HTTP/stand-in SSH clone/fetch with Git, and inflate with Zig flate/system zlib.

From `bench/`, run `./run.sh` or `./transport/run.sh` on a quiet machine.
`BENCH_SMOKE=1` selects a one-file/one-change fixture and one iteration
without warm-up. Full runs take best-of-five after warm-up (`PASSES`);
write workloads default to at most three. `./run.sh build` builds only.
Both harnesses consume this repository (`..` or `../..`).

Rust gix 0.87.1/git2 0.21.0 and pack-writing crates are exact in
`src/rival_rs/Cargo.toml`, with transitive pins in `Cargo.lock`.
Go go-git v5.19.2 is pinned in `src/rival_go/go.mod`/`go.sum`. Git, zlib,
standard libraries and Zig use installed tools; record versions with results.
`BENCH_BUILD_DIR`/`BENCH_RESULTS` select output, defaulting to `build/`;
`BENCH_FIXTURE`, `SIZES`, `PASSES` control fixtures/runs. `ZIG`, `GO`,
`CARGO`, `PYTHON` select tools. All generated files are ignored.

`zig build regressions-build` compiles without measuring.
`zig build regressions --summary all` runs the former unit-suite measurements
on a quiet machine: cold/warm staging, cache-tree reuse, status, packed delta
reads, SHA throughput, loose versus packed staging, and whole/delta pack
writing. The timing ratios and ceilings live here; shared CI runs deterministic
work and result checks instead. This command is part of the bench harness only.

## Earlier measurements

**Speed.** `zig build regressions --summary all` runs the measurements. On an Apple M3 Max, over three thousand files in sixty
directories and 64 MiB hashed:

| | |
|---|---|
| `addAll`, nothing staged yet | 426 ms |
| `addAll`, nothing staged yet, into one pack | 68 ms |
| `addAll`, nothing changed | 5 ms |
| `writeTree`, cache tree invalid | 9 ms |
| `writeTree`, cache tree valid | under a millisecond |
| `status`, one file in ten changed | 8 ms |
| writing a deltified pack | 7 200 objects/s, 41 MiB/s of input |
| SHA-1, the eighty rounds in software | 0.99 GiB/s |
| SHA-1, the aarch64 instructions | 2.47 GiB/s |
| SHA-1, with the collision check | 0.41 GiB/s |
| SHA-256, from the standard library | 2.29 GiB/s |

The warm numbers are what the stat shortcut and the `TREE` extension are for:
an entry whose recorded stat still matches is neither opened nor hashed, and a
cache-tree node that is still valid is used as it stands.

The first cold number is three thousand loose objects written, and it was
profiled before it was worked on. Naming them is under a millisecond, so it
is not the number to read the hash by. Two calls are three quarters of it: the
`O_CREAT|O_EXCL` that makes each temporary, at 35 µs, and the `rename` that
finishes it, at 54 µs. Those are the filesystem's own figures — the same two
calls straight through libc cost the same, so nothing is lost in a layer — and
they are what one file per object costs on APFS. What was around them has
gone: a `mkdir`, an `opendir` and a `close` per object became one `mkdir` per
fan-out directory, of which at most two hundred and fifty-six exist; the walk
asks the filesystem once per entry instead of twice, and on macOS once per
*directory*; and a file whose length a stat has already reported is read
without asking again. The benchmark asserts on the counts rather than the
clock for that first one: three thousand objects written, at most two hundred
and fifty-six directories made.

A pack is one file where loose objects are one file each, which is the whole
of the second row: the same three thousand files staged into one pack rather
than three thousand loose objects is 392 ms against 68 ms, measured in one run
of the same test, and the tree that comes out is the same tree. What it gives
up is that another reader sees nothing until the pass is over, and that
nothing is deltified — a delta wants the object before it and a walk hands
them over one at a time. `Odb.repack` is what deltifies.

The pack figures are a repository of twenty files each grown over six
commits, 138 objects: the deltified pack is 29 692 bytes where the same
objects written whole are 84 871. What the test asserts of the two is that the
deltified one used deltas and came out smaller.

Timing ratios and ceilings belong to this quiet-machine harness. Shared
unit-suite builds compare hashes, trees, object counts, reads and bytes.

The former library text also quoted three measured costs: macOS full sync
at about thirty times a writeout sync, the previous inflater at about twice
zlib, and checked SHA-1 at about five times an unchecked hash. Treat these
as historical observations to remeasure on a quiet machine, not guarantees.

Historical upstream TLS cipher measurements (Zig 0.11 development version):

```text
Measurement taken with 0.11.0-dev.810+c2f5848fe
on x86_64-linux Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz:
zig run .lib/std/crypto/benchmark.zig -OReleaseFast
      aegis-128l:      15382 MiB/s
       aegis-256:       9553 MiB/s
      aes128-gcm:       3721 MiB/s
      aes256-gcm:       3010 MiB/s
chacha20Poly1305:        597 MiB/s

Measurement taken with 0.11.0-dev.810+c2f5848fe
on x86_64-linux Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz:
zig run .lib/std/crypto/benchmark.zig -OReleaseFast -mcpu=baseline
      aegis-128l:        629 MiB/s
chacha20Poly1305:        529 MiB/s
       aegis-256:        461 MiB/s
      aes128-gcm:        138 MiB/s
      aes256-gcm:        120 MiB/s
```
