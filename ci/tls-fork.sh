#!/usr/bin/env bash
#
# relic — the TLS client's diff against the standard library's, taken again.
#
# src/transport/tls/Client.zig is Zig's lib/std/crypto/tls/Client.zig with client
# authentication added, and src/transport/tls/Client.zig.diff is the whole of what was
# added: the diff from the std file to ours, with the std file's SHA-256 in
# its first line. src/testing/tls_fork.zig holds the two to it on every
# `zig build test`. Run this after bringing std's changes across, or after
# changing the client, and commit the diff it writes.
#
# Usage: ci/tls-fork.sh          # rewrites src/transport/tls/Client.zig.diff
#        ci/tls-fork.sh --check  # fails if the committed diff is not current

set -euo pipefail
cd "$(dirname "$0")/.."

lib_dir=$(zig env | sed -n 's/^ *\.lib_dir = "\(.*\)",$/\1/p')
std_client="$lib_dir/std/crypto/tls/Client.zig"
[ -f "$std_client" ] || { echo "no std TLS client at $std_client" >&2; exit 1; }
version=$(zig version)
hash=$(shasum -a 256 "$std_client" | cut -d' ' -f1)

out=$(mktemp)
trap 'rm -f "$out"' EXIT
# diff exits 1 when the files differ, which is the point.
diff -u \
    --label "std/crypto/tls/Client.zig zig-$version sha256:$hash" \
    --label "src/transport/tls/Client.zig" \
    "$std_client" src/transport/tls/Client.zig >"$out" || [ $? -eq 1 ]

if [ "${1:-}" = "--check" ]; then
    if ! cmp -s "$out" src/transport/tls/Client.zig.diff; then
        echo "src/transport/tls/Client.zig.diff is not the diff of src/transport/tls/Client.zig against $std_client" >&2
        diff "$out" src/transport/tls/Client.zig.diff >&2 || true
        exit 1
    fi
    exit 0
fi
cp "$out" src/transport/tls/Client.zig.diff
echo "src/transport/tls/Client.zig.diff: against zig $version, sha256 $hash"
