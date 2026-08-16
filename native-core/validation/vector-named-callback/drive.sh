#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-vector-named-callback.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

"$repo/bin/beagle" native-exe \
  --out "$scratch/probe" \
  --artifacts "$scratch/artifacts" \
  --entry native.vector-named-callback/-main \
  "$here/provider.bgl" "$here/fixture.bgl"
"$scratch/probe"

echo "vector-named-callback: qualified record accessor mapv PASS"
