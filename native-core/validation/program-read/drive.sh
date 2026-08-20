#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/program-read.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

module_roots=(
  --module-root "store/src=$repo/store/src"
  --module-root "native-core/src=$repo/native-core/src"
)

echo "program-read: typed module check"
timeout --foreground 30s \
  "$repo/bin/beagle" check --agent "${module_roots[@]}" "$here/fixture.bgl"

echo "program-read: native semantic fixture build"
timeout --foreground 120s \
  "$repo/bin/beagle-native-exe" \
    "${module_roots[@]}" \
    --out "$scratch/program-read" \
    --artifacts "$scratch/artifacts" \
    --entry program-read.fixture/main \
    -- "$here/fixture.bgl" >"$scratch/native-exe.log"

echo "program-read: native semantic fixture run"
timeout --foreground 10s "$scratch/program-read"

echo "program-read: FNF query plans, root scoping, and occurrence history PASS"
