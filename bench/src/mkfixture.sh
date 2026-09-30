#!/usr/bin/env bash
# Build the benchmark fixture once. Everything lands under build/fixture:
#   repo-loose    the repository with every object loose (no repack), .git only
#   repo-packed   the same history after `git repack -adf`
#   blobs.txt     every blob name in repo-packed, one per line
#   head.txt      the commit HEAD points at
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fx="${BENCH_FIXTURE:-$here/build/fixture${BENCH_SMOKE:+-smoke}}"
if [ -f "$fx/.done" ]; then echo "fixture: already built"; exit 0; fi
rm -rf "$fx"; mkdir -p "$fx"
echo "fixture: generating synthetic history"
"${PYTHON:-python3}" "$here/src/genfixture.py" "$fx/work"
# The loose copy is the repository before any repack. Its working tree is
# removed: no side reads it in the pack workload, and `run.sh` copies this
# directory fresh for every measured run, which 20 000 files it never opens
# would make several times more expensive.
cp -ac "$fx/work" "$fx/repo-loose"
find "$fx/repo-loose" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git -C "$fx/work" repack -adf -q
git -C "$fx/work" status --porcelain >/dev/null   # warm the index
mv "$fx/work" "$fx/repo-packed"
git -C "$fx/repo-packed" rev-parse HEAD > "$fx/head.txt"
git -C "$fx/repo-packed" cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype)' \
  | awk '$2=="blob"{print $1}' > "$fx/blobs.txt"
git -C "$fx/repo-packed" cat-file --batch-all-objects --batch-check='%(objectname)' > "$fx/allobjects.txt"
du -sh "$fx/repo-loose" "$fx/repo-packed" | sed 's/^/fixture: /'
wc -l < "$fx/blobs.txt" | sed 's/^/fixture: blobs /'
touch "$fx/.done"
