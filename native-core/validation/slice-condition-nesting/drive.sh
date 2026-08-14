#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_CONDITION_NESTING_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-condition-nesting.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

timeout --signal=TERM 120s "$repo/bin/beagle" build \
  --materializer c17 \
  --out "$scratch/artifact" \
  --entry native.short-circuit/nested-short-circuit \
  -- "$here/fixture.bgl"

report="$scratch/artifact/report.txt"
grep -Fxq 'stage typed-to-native COMPLETE' "$report"
grep -Eq '^lowered fn_[0-9]+ nested-short-circuit [1-9][0-9]* blocks$' "$report"
grep -Fxq 'result PASS' "$report"

echo "slice-condition-nesting: PASS nested and/or joins have unique SSA identities"
