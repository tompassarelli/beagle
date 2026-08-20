#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/store-epistemic-fact.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

sources=(
  "$repo/store/src/store/slots.bgl"
  "$repo/store/src/store/types.bgl"
  "$repo/store/src/store/store.bgl"
  "$repo/store/src/store/rotation.bgl"
  "$repo/store/src/store/txn.bgl"
  "$repo/store/src/store/epistemic_fact.bgl"
  "$here/fixture.bgl"
)

timeout --foreground 30s "$repo/bin/beagle" check --agent "${sources[@]}"
timeout --foreground 110s "$repo/bin/beagle" native-exe \
  --out "$scratch/epistemic-fact" \
  --artifacts "$scratch/artifacts" \
  --entry store.epistemic-fact-fixture/main \
  "${sources[@]}"
timeout --foreground 10s "$scratch/epistemic-fact"

rg -qx 'stage typed-to-native COMPLETE' "$scratch/artifacts/report.txt"
rg -qx 'result PASS' "$scratch/artifacts/report.txt"

echo "epistemic-fact: admitted envelopes persist and reconstruct PASS"
