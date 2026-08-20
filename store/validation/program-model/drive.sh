#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/store-program-model.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

supervisor="$repo/store/tests/run_hosted_test.sh"

run_bounded() {
  BEAGLE_STORE_HOSTED_TEST_KILL_AFTER=5s \
    "$supervisor" "$@"
}

model_sources=(
  "$repo/store/src/store/slots.bgl"
  "$repo/store/src/store/types.bgl"
  "$repo/store/src/store/kernel.bgl"
  "$repo/store/src/store/program.bgl"
  "$here/fixture.bgl"
)

check_sources=(
  "${model_sources[@]}"
  "$repo/native-core/src/beagle/checker.bgl"
  "$repo/native-core/src/beagle/datum_reader.bgl"
  "$repo/native-core/src/beagle/frontend_facts.bgl"
  "$repo/native-core/src/beagle/js_materializer.bgl"
  "$repo/native-core/src/beagle/parser.bgl"
  "$repo/native-core/src/beagle/parser_reader.bgl"
  "$repo/native-core/src/beagle/syntax_semantics.bgl"
  "$repo/native-core/validation/js-materializer/fixture.bgl"
  "$repo/native-core/validation/native-checker/fixture.bgl"
  "$repo/native-core/validation/parser/fixture.bgl"
)

run_bounded 30s "$repo/bin/beagle" check --agent "${check_sources[@]}"
run_bounded 110s "$repo/bin/beagle" native-exe \
  --out "$scratch/program-model" \
  --artifacts "$scratch/artifacts" \
  --entry store.program-model-fixture/main \
  "${model_sources[@]}"
run_bounded 10s "$scratch/program-model"

rg -qx 'stage typed-to-native COMPLETE' "$scratch/artifacts/report.txt"
rg -qx 'result PASS' "$scratch/artifacts/report.txt"

echo "program-model: canonical recursive Triple FNF admission PASS"
