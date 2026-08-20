#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-parser-closure.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

sources=(
  "$repo/native-core/src/beagle/frontend_facts.bgl"
  "$repo/native-core/src/beagle/parser.bgl"
  "$here/fixture.bgl"
)

"$repo/bin/beagle" check --agent "${sources[@]}"
"$repo/bin/beagle-native-exe" \
  --out "$scratch/parser-fixture" \
  --artifacts "$scratch/artifacts" \
  --entry parser.fixture/main \
  -- "${sources[@]}" >"$scratch/native-exe.log"
"$scratch/parser-fixture"

echo "native parser explicit closure fixture: PASS"
