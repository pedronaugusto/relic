#!/usr/bin/env bash
#
# relic — the git the Linux image builds and the git CI's Linux job builds
# are the same git: one version and one set of make flags.
#
# The two are written twice, in ci/linux.Dockerfile and in
# .github/workflows/ci.yml, and drifted once: the job built without
# NO_RUST. This compares them and fails on any difference.
#
# Usage: ci/git-flags.sh

set -euo pipefail
cd "$(dirname "$0")/.."

# The flags of every `make ... prefix=/opt/git` line, sorted, one set.
flags() {
    grep -oE 'make -C [^ ]+ .*prefix=/opt/git' "$1" |
        tr ' ' '\n' | grep -E '^[A-Z_]+=' | sort -u
}
version() {
    grep -oE 'GIT_VERSION[=:] *[0-9.]+' "$1" | head -1 | grep -oE '[0-9.]+$'
}

image=ci/linux.Dockerfile
job=.github/workflows/ci.yml
status=0
if [ "$(version "$image")" != "$(version "$job")" ]; then
    echo "git version: $image has $(version "$image"), $job has $(version "$job")" >&2
    status=1
fi
if ! diff <(flags "$image") <(flags "$job") >&2; then
    echo "git make flags differ: < $image, > $job" >&2
    status=1
fi
[ "$status" -eq 0 ] && echo "git: $(version "$image"), $(flags "$image" | tr '\n' ' ')"
exit "$status"
