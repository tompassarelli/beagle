#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/store-model-resource-policy.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

supervisor="$repo/store/tests/run_hosted_test.sh"

run_bounded() {
  BEAGLE_STORE_HOSTED_TEST_KILL_AFTER=5s \
    "$supervisor" "$@"
}

sources=(
  "$repo/store/src/store/model_revision_resource_policy.bgl"
  "$here/fixture.bgl"
)

run_bounded 30s "$repo/bin/beagle" syntax "${sources[@]}"
run_bounded 30s "$repo/bin/beagle" check --agent "${sources[@]}"
run_bounded 90s "$repo/bin/beagle" native-exe \
  --out "$scratch/model-resource-policy" \
  --artifacts "$scratch/artifacts" \
  --entry store.model-revision-resource-policy-fixture/main \
  "${sources[@]}"
run_bounded 10s "$scratch/model-resource-policy"

rg -qx 'stage typed-to-native COMPLETE' "$scratch/artifacts/report.txt"
rg -qx 'result PASS' "$scratch/artifacts/report.txt"

echo "model-resource-policy: typed six-dimension admission PASS"
