# Clone, fetch and inflate

Run `./run.sh` on a quiet machine; `BENCH_SMOKE=1 ./run.sh` uses one file and
one pass. `SIZES` and `PASSES` control a full run. HTTP uses a local Git
http-backend; SSH uses `src/ssh-standin.sh`, so no remote credentials are needed.

The inflate comparison builds with:

```sh
zig build-exe -OReleaseFast -lz -lc --dep inflate -Mroot=src/inflate_bench.zig \
  -Minflate=../../src/inflate.zig -femit-bin=build/inflate_bench
build/inflate_bench build/fixture/smoke.git/objects/pack/pack-*.pack 1
```

Git, zlib and Zig flate come from the installed toolchains. The package under
test is this repository. Record toolchain versions with full results.
