#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/native-source-freeze-path.XXXXXX")"
trap 'rm -rf "${work:?}"' EXIT

run_case() {
  local label="$1"
  local cwd="$2"
  local case_dir="$work/$label"
  local scratch="$case_dir/scratch"
  local store_checkout
  local source
  mkdir -p "$case_dir/artifacts"
  printf 'source-freeze path case %s: START from %s\n' "$label" "$cwd"
  (
    cd "$cwd"
    store_checkout="$("$repo/native-core/validation/store-checkout.sh")"
    source="$store_checkout/src/fram/types.bgl"
    mkdir -p "$scratch"
    "$repo/bin/beagle-facts" --module-root "store/src=$store_checkout/src" \
      "$source" >"$scratch/facts.raw"
    {
      printf '[\n'
      tail -n +2 "$scratch/facts.raw"
      printf ']\n'
    } >"$scratch/facts.edn"
    "$repo/bin/beagle-build-all" \
      "$repo/native-core/src/native/core.bclj" \
      "$repo/native-core/src/native/stages.bclj" \
      "$repo/native-core/src/native/lower.bclj" \
      "$repo/native-core/src/native/obligations.bclj" \
      "$repo/native-core/src/native/simd.bclj" \
      "$repo/native-core/src/native/c11.bclj" \
      "$repo/native-core/validation/slice-types/pipeline.bclj" \
      --out "$scratch/out" >"$case_dir/build.log" 2>&1
    bb -cp "$scratch/out" \
      "$repo/native-core/tests/source_freeze_probe.clj" \
      "$scratch/facts.edn" "$source" "$case_dir/artifacts/report.txt"
  )
  grep -Fx 'stage source-freeze ACCEPTED' "$case_dir/artifacts/report.txt"
  printf 'source-freeze path case %s: ACCEPTED from %s\n' "$label" "$cwd"
}

run_case repo "$repo"
run_case tmp /tmp
