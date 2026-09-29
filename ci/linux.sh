#!/usr/bin/env bash
#
# relic — the suite on Linux, from a machine that is not one.
#
# The promises this package makes are about files: an exclusive create, a
# rename, an `fsync`. Those are the parts of a filesystem that differ most
# between kernels, so "it passes here" is not the same claim as "it passes on
# the machine this runs on". This builds the image in ci/linux.Dockerfile --
# Debian plus the pinned Zig plus a pinned git for the fixtures -- and runs the
# whole suite inside it, in Debug and in ReleaseSafe.
#
# The image is tagged with a digest of the Dockerfile, so it is built once per
# version of that file: a rerun finds it and starts at once, and a change to
# the pinned git or Zig builds a new one rather than running an old one.
#
# The suite runs on a copy of the checkout inside the container, not on the
# checkout itself. A bind mount from macOS is the host's filesystem seen
# through virtiofs, and it keeps the host's rules: there root may execute a
# file with no execute bit, and git finds changes in a work tree nobody
# touched. The promises under test are Linux's, so the files the tests make
# live on the container's own filesystem. The caches go under /tmp with them,
# and the repository's own .zig-cache, which holds objects for the host's
# architecture, is left alone.
#
# Usage: ci/linux.sh [extra zig build args...]

set -euo pipefail
cd "$(dirname "$0")/.."

digest=$(git hash-object ci/linux.Dockerfile | cut -c1-12)
image=${RELIC_LINUX_IMAGE:-relic-linux-$digest}

if ! command -v docker >/dev/null 2>&1; then
    echo "ci/linux.sh needs docker on PATH." >&2
    exit 1
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "==> building $image"
    docker build -f ci/linux.Dockerfile -t "$image" ci
fi
docker run --rm "$image" git --version
docker run --rm "$image" sh -ec 'gpg --version | head -1; command -v gpgconf ssh-keygen'

for mode in Debug ReleaseSafe; do
    echo "==> zig build test -Doptimize=$mode (linux, in $image)"
    docker run --rm \
        -e RELIC_REQUIRE_SIGNERS=1 \
        -v "$PWD:/src:ro" \
        "$image" \
        sh -ec '
            mkdir /tmp/relic
            tar -C /src --exclude=./.zig-cache --exclude=./zig-out -cf - . | tar -C /tmp/relic -xf -
            cd /tmp/relic
            exec zig build test --cache-dir /tmp/zc --global-cache-dir /tmp/zg "$@"
        ' sh -Doptimize="$mode" "$@"
done

echo "==> zig fmt --check (linux)"
docker run --rm -v "$PWD:/src:ro" -w /src "$image" \
    zig fmt --check src examples build.zig

echo "all green on linux."
