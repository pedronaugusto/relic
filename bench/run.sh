#!/usr/bin/env bash
#
# relic against the field: build every side, run every workload, print a
# table and write results.tsv beside this script. Idempotent and unattended.
#
#   ./run.sh              build what is missing, then run everything
#   ./run.sh build        build only
#   ./run.sh fixture      build the fixture only
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
build="${BENCH_BUILD_DIR:-$here/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
results="${BENCH_RESULTS:-$build/results.tsv}"
fx="${BENCH_FIXTURE:-$build/fixture${BENCH_SMOKE:+-smoke}}"
export BENCH_FIXTURE="$fx"
scratch="$build/scratch"
runs="$build/runs"
mkdir -p "$build" "$scratch"

say() { printf '== %s\n' "$*" >&2; }

#---------------------------------------------------------------------------
# Build the package in this repository.
# Every intermediate lands under build/: cargo's target directory and zig's
# install prefix are pointed there rather than left beside the sources.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$build/cargo-target}"

build_all() {
  say "building relic side (zig, ReleaseFast)"
  (cd "$here" && "${ZIG:-zig}" build -j1 --prefix "$build/zig" --cache-dir "$build/zig-cache" -Doptimize=ReleaseFast -Dsmoke=$([ "${BENCH_SMOKE:-0}" = 1 ] && echo true || echo false))
  say "building rust side (cargo --release: gix, libgit2)"
  (cd "$here/src/rival_rs" && "${CARGO:-cargo}" build -j1 --release --locked --quiet)
  # Replace the inode: overwriting an executed Mach-O can retain stale code-signature state.
  rm -f "$build/git2_bench" "$build/gix_bench"
  cp -f "$CARGO_TARGET_DIR/release/git2_bench" "$build/git2_bench"
  cp -f "$CARGO_TARGET_DIR/release/gix_bench" "$build/gix_bench"
  say "building go side ("${GO:-go}" build -p=1 -mod=readonly -ldflags='-s -w')"
  (cd "$here/src/rival_go" && "${GO:-go}" build -p=1 -mod=readonly -ldflags="-s -w" -o "$build/gogit_bench" .)
  say "git: $(git --version)"
  say "relic: $(git -C "$here/.." rev-parse --short HEAD)"
}

#---------------------------------------------------------------------------
# The fixture: one synthetic repository, generated once, read by every side.
#---------------------------------------------------------------------------
fixture() { "$here/src/mkfixture.sh"; }

#---------------------------------------------------------------------------
# Running one point: a warm-up run, then five measured runs, best kept.
#---------------------------------------------------------------------------
# Best of five measured runs, plus one warm-up that is thrown away.
# PASSES=1 is the smoke setting: it proves the harness, not the numbers.
PASSES="${PASSES:-5}"
[ "${BENCH_SMOKE:-0}" != 1 ] || PASSES=1
# The two write workloads copy the repository fresh for every run, which on
# this fixture costs more than the work does, so they take the best of three.
# Never more than PASSES, so PASSES=1 stays a one-pass smoke run.
WRITE_PASSES="${WRITE_PASSES:-$(( PASSES < 3 ? PASSES : 3 ))}"

prep_none() { :; }

# A fresh copy of the packed repository with 1 % of its files modified, and a
# warm index: `cp` does not preserve ctime, so without the refresh every side
# would re-hash all 20 000 files instead of the 200 that changed.
prep_addall() {
  rm -rf "$scratch/addall"
  # -c asks APFS for a clone rather than a copy of the bytes.
  cp -ac "$fx/repo-packed" "$scratch/addall"
  git -C "$scratch/addall" update-index --refresh -q >/dev/null 2>&1 || true
  "${PYTHON:-python3}" "$here/src/mutate.py" "$scratch/addall" >/dev/null
}

# A fresh copy of the loose-object repository.
prep_packwrite() {
  rm -rf "$scratch/loose"
  cp -ac "$fx/repo-loose" "$scratch/loose"
  rm -f "$scratch"/gitpack-* "$scratch"/gogit.pack
}

point() {
  local side="$1" workload="$2" prep="$3"; shift 3
  local dir="$runs/$side-$workload"
  rm -rf "$dir"; mkdir -p "$dir"
  local passes="$PASSES"
  [ "$prep" = prep_none ] || passes="$WRITE_PASSES"
  local i
  for i in $(seq "$([ "${BENCH_SMOKE:-0}" = 1 ] && echo 1 || echo 0)" "$passes"); do
    "$prep"
    if ! "$@" > "$dir/$i.tsv" 2> "$dir/$i.err"; then
      # A side that cannot do a workload says so in the table rather than
      # taking the run down with it.
      {
        printf '%s\t%s\ttime\tERROR\tn/a\n' "$side" "$workload"
        printf '%s\t%s\tmessage\t%s\tn/a\n' "$side" "$workload" \
          "$(tail -n 1 "$dir/$i.err" | tr '\t' ' ' | cut -c1-120)"
      } > "$dir/$i.tsv"
      say "$side $workload FAILED: $(tail -n 1 "$dir/$i.err" | cut -c1-100)"
      break
    fi
  done
  # Run 0 is the warm-up and is thrown away.
  local measured=("$dir"/[1-9]*.tsv)
  if [ -e "${measured[0]}" ]; then
    "${PYTHON:-python3}" "$here/src/pick.py" "${measured[@]}"
  else
    cat "$dir/0.tsv"
  fi
}

RELIC="$build/zig/bin/relic_bench"
GIT2="$build/git2_bench"
GIX="$build/gix_bench"
GOGIT="$build/gogit_bench"
GITPY=("${PYTHON:-python3}" "$here/src/git_bench.py")

run_all() {
  local out="$results"
  : > "$out"

  say "workload 1/6: status"
  point relic   status prep_none "$RELIC" status   "$fx/repo-packed" >> "$out"
  point git     status prep_none "${GITPY[@]}" status "$fx/repo-packed" >> "$out"
  point gix     status prep_none "$GIX"   status   "$fx/repo-packed" >> "$out"
  point libgit2 status prep_none "$GIT2"  status   "$fx/repo-packed" >> "$out"
  point go-git  status prep_none "$GOGIT" status   "$fx/repo-packed" >> "$out"

  say "workload 2/6: add-all + write-tree"
  point relic   addall prep_addall "$RELIC" addall "$scratch/addall" >> "$out"
  point git     addall prep_addall "${GITPY[@]}" addall "$scratch/addall" >> "$out"
  # gix prints n/a without opening anything, so it needs no fresh copy.
  point gix     addall prep_none   "$GIX"   addall "$scratch/addall" >> "$out"
  point libgit2 addall prep_addall "$GIT2"  addall "$scratch/addall" >> "$out"
  point go-git  addall prep_addall "$GOGIT" addall "$scratch/addall" >> "$out"

  say "workload 3/6: rev-list walk"
  point relic   revlist prep_none "$RELIC" revlist "$fx/repo-packed" >> "$out"
  point git     revlist prep_none "${GITPY[@]}" revlist "$fx/repo-packed" >> "$out"
  point gix     revlist prep_none "$GIX"   revlist "$fx/repo-packed" >> "$out"
  point libgit2 revlist prep_none "$GIT2"  revlist "$fx/repo-packed" >> "$out"
  point go-git  revlist prep_none "$GOGIT" revlist "$fx/repo-packed" >> "$out"

  say "workload 4/6: cat all blobs through the pack"
  point relic   catblobs prep_none "$RELIC" catblobs "$fx/repo-packed" "$fx/blobs.txt" >> "$out"
  point git     catblobs prep_none "${GITPY[@]}" catblobs "$fx/repo-packed" "$fx/blobs.txt" >> "$out"
  point gix     catblobs prep_none "$GIX"   catblobs "$fx/repo-packed" "$fx/blobs.txt" >> "$out"
  point libgit2 catblobs prep_none "$GIT2"  catblobs "$fx/repo-packed" "$fx/blobs.txt" >> "$out"
  point go-git  catblobs prep_none "$GOGIT" catblobs "$fx/repo-packed" "$fx/blobs.txt" >> "$out"

  say "workload 5/6: pack write"
  point relic   packwrite prep_packwrite "$RELIC" packwrite "$scratch/loose" >> "$out"
  point git     packwrite prep_packwrite "${GITPY[@]}" packwrite "$scratch/loose" "$scratch" >> "$out"
  point gix     packwrite prep_packwrite "$GIX"   packwrite "$scratch/loose" "$scratch" >> "$out"
  point libgit2 packwrite prep_packwrite "$GIT2"  packwrite "$scratch/loose" "$scratch" >> "$out"
  point go-git  packwrite prep_packwrite "$GOGIT" packwrite "$scratch/loose" "$scratch" >> "$out"

  say "workload 6/6: index read + write"
  point relic   indexrw prep_none "$RELIC" indexrw "$fx/repo-packed" "$scratch" >> "$out"
  point git     indexrw prep_none "${GITPY[@]}" indexrw "$fx/repo-packed" "$scratch" >> "$out"
  point gix     indexrw prep_none "$GIX"   indexrw "$fx/repo-packed" "$scratch" >> "$out"
  point libgit2 indexrw prep_none "$GIT2"  indexrw "$fx/repo-packed" "$scratch" >> "$out"
  point go-git  indexrw prep_none "$GOGIT" indexrw "$fx/repo-packed" "$scratch" >> "$out"

  # The copies are large; nothing reads them after the last run.
  rm -rf "$scratch/addall" "$scratch/loose"
  "${PYTHON:-python3}" "$here/src/table.py" "$out"
}

case "${1:-all}" in
  build)   build_all ;;
  fixture) fixture ;;
  table)   "${PYTHON:-python3}" "$here/src/table.py" "$results" ;;
  all)     build_all; fixture; run_all ;;
  *)       echo "usage: run.sh [all|build|fixture|table]" >&2; exit 2 ;;
esac
