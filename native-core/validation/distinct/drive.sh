#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-distinct.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "distinct: $*" >&2
  exit 1
}

timeout --foreground 30s "$repo/bin/beagle" check --agent "$here/fixture.bgl"
timeout --foreground 180s "$repo/bin/beagle-native-exe" \
  --out "$scratch/distinct-fixture" \
  --artifacts "$scratch/artifacts" \
  --entry native.distinct/main \
  -- "$here/fixture.bgl"

timeout --foreground 10s "$scratch/distinct-fixture" \
  || die "Native C17 execution rejected a distinct behavior"

rg -qx 'stage typed-to-native COMPLETE' "$scratch/artifacts/report.txt" \
  || die "native lowering did not complete"
rg -q '^lowered .* distinct-values ' "$scratch/artifacts/report.txt" \
  || die "the typed distinct wrapper did not lower"
rg -q 'TODO-NATIVE-DISTINCT' "$scratch/artifacts/report.txt" \
  && die "a distinct lowering rejection remains"
rg -q '^native-exe-c17 PASS ' "$scratch/artifacts/native-exe.report.txt" \
  || die "Native C17 executable report did not pass"

echo "distinct: empty, already distinct, duplicate removal, and first-occurrence order PASS"
