#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-sort-by.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "sort-by: $*" >&2
  exit 1
}

timeout --foreground 30s "$repo/bin/beagle" check --agent "$here/fixture.bgl"
timeout --foreground 180s "$repo/bin/beagle-native-exe" \
  --out "$scratch/sort-by-fixture" \
  --artifacts "$scratch/artifacts" \
  --entry native.sort-by/main \
  -- "$here/fixture.bgl"

timeout --foreground 10s "$scratch/sort-by-fixture" \
  || die "Native C17 execution rejected sort-by behavior"

rg -qx 'stage typed-to-native COMPLETE' "$scratch/artifacts/report.txt" \
  || die "native lowering did not complete"
rg -q '^lowered .* sort-texts ' "$scratch/artifacts/report.txt" \
  || die "the typed text-key sort-by wrapper did not lower"
rg -q '^lowered .* sort-by-length ' "$scratch/artifacts/report.txt" \
  || die "the typed Int-key sort-by wrapper did not lower"
rg -q 'TODO-NATIVE-SORT-BY' "$scratch/artifacts/report.txt" \
  && die "a sort-by lowering rejection remains"
rg -q '^native-exe-c17 PASS ' "$scratch/artifacts/native-exe.report.txt" \
  || die "Native C17 executable report did not pass"

echo "sort-by: empty, sorted, reverse, and equal-key stability PASS"
