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
