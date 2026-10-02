#!/usr/bin/env bash
#
# relic's clone and fetch against git's, over HTTP (git http-backend behind a
# keep-alive HTTP/1.1 server) and ssh (a stand-in running git's programs on
# this machine). Both clients talk to the same git server. Results go to
# results.tsv beside this script, appended to (empty it for a fresh run):  <size> <transport> <workload> <side> <best_ms> <median_ms>
#
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="${BENCH_BUILD_DIR:-$here/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
results="${BENCH_RESULTS:-$build/results.tsv}"
fx="$build/fixture"
work="$build/work"
bench_home="$build/home"
bench="$build/zig/bin/relic_transport_bench"
mkdir -p "$fx" "$work" "$bench_home"
say() { printf '== %s\n' "$*" >&2; }

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="$here/src/ssh-standin.sh"
# No detached gc or maintenance after git's fetch, which would write into the
# next run's directory and take the machine from it; relic starts none.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0 GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
unset GIT_DIR GIT_WORK_TREE SSH_AUTH_SOCK || true

# size: files bytes commits touched extra
spec() { case $1 in smoke) echo "1 32 1 1 1" ;; small) echo "200 1000 100 3 20" ;; medium) echo "3000 2000 1000 10 20" ;; large) echo "20000 2000 300 20 20" ;; esac; }
SIZES="${SIZES:-small medium large}"
[ "${BENCH_SMOKE:-0}" != 1 ] || SIZES=smoke
PASSES="${PASSES:-5}"
[ "${BENCH_SMOKE:-0}" != 1 ] || PASSES=1

fixture() {
  local size=$1
  [ -d "$fx/$size.git" ] && return
  say "fixture $size: $(spec "$size")"
  git init -q --bare "$fx/$size.git"
  "${PYTHON:-python3}" "$here/src/genrepo.py" $(spec "$size") | git -C "$fx/$size.git" fast-import --quiet --done
  git -C "$fx/$size.git" repack -adq
  git clone -q --bare "$fx/$size.git" "$fx/$size-base.git"
  git -C "$fx/$size-base.git" update-ref refs/heads/main refs/tags/base
  git -C "$fx/$size-base.git" repack -adq
  git -C "$fx/$size-base.git" prune
  # The clients the fetches start from, made by git: at the tip, and at base.
  git clone -q --no-checkout "$fx/$size.git" "$fx/$size-client-tip"
  git clone -q --no-checkout "$fx/$size-base.git" "$fx/$size-client-base"
}

# Milliseconds of wall time for the command, process start included.
wall() { perl -MTime::HiRes=time -e '$t=time; system(@ARGV)==0 or exit 1; printf "%.1f\n", (time-$t)*1000' "$@"; }

stats() { sort -n | awk '{a[NR]=$1} END {printf "%s\t%s\n", a[1], a[int((NR+1)/2)]}'; }

point() {  # size transport workload side url
  local size=$1 transport=$2 workload=$3 side=$4 url=$5 t out
  local dst="$work/dst"
  local times=()
  for pass in $(seq "$([ "${BENCH_SMOKE:-0}" = 1 ] && echo 1 || echo 0)" "$PASSES"); do
    rm -rf "$dst"
    case $workload in
      fetch-noop) cp -R "$fx/$size-client-tip" "$dst"; git -C "$dst" config remote.origin.url "$url" ;;
      fetch-new)  cp -R "$fx/$size-client-base" "$dst"; git -C "$dst" config remote.origin.url "$url" ;;
    esac
    case "$workload/$side" in
      clone/git)          t=$(wall git clone -q --bare "$url" "$dst") ;;
      clone/relic)        t=$("$bench" clone "$url" "$dst") ;;
      clone/relic-fsck)   t=$("$bench" clone "$url" "$dst" check) ;;
      fetch-*/git)        t=$(wall git -C "$dst" fetch -q origin) ;;
      fetch-*/relic)      t=$("$bench" fetch "$dst") ;;
    esac
    [ "$pass" = 0 ] && continue   # the warm-up
    times+=("$t")
  done
  out=$(printf '%s\n' "${times[@]}" | stats)
  printf '%s\t%s\t%s\t%s\t%s\n' "$size" "$transport" "$workload" "$side" "$out" | tee -a "$results"
}

zig_build() {
  (cd "$here" && "${ZIG:-zig}" build -j1 -Doptimize=ReleaseFast --prefix "$build/zig" --cache-dir "$build/zig-cache")
}

server=""
main() {
  zig_build
  for size in $SIZES; do fixture "$size"; done
  [ "${1:-}" = fixture ] && return
  local port_file="$build/port"
  rm -f "$port_file"
  "${PYTHON:-python3}" "$here/src/httpgit.py" "$fx" > "$port_file" 2>/dev/null &
  server=$!
  trap '[ -n "$server" ] && kill "$server" 2>/dev/null || true' EXIT
  while [ ! -s "$port_file" ]; do sleep 0.1; done
  local port; port=$(cat "$port_file")
  say "relic $(git -C "$here/../.." rev-parse --short HEAD), $(git --version), load $(uptime | sed 's/.*averages: //')"
  for size in $SIZES; do
    for transport in http ssh; do
      local url base_url
      if [ $transport = http ]; then url="http://127.0.0.1:$port/$size.git"; base_url="http://127.0.0.1:$port/$size-base.git"
      else url="ssh://bench.invalid$fx/$size.git"; base_url="ssh://bench.invalid$fx/$size-base.git"; fi
      for side in git relic relic-fsck; do point "$size" "$transport" clone "$side" "$url"; done
      for side in git relic; do point "$size" "$transport" fetch-noop "$side" "$url"; done
      for side in git relic; do point "$size" "$transport" fetch-new "$side" "$url"; done
    done
  done
}
main "$@"
