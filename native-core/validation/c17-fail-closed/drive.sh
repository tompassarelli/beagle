#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_C17_FAIL_CLOSED_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-c17-fail-closed.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/fold_c17.bclj" \
  "$repo/native-core/src/native/simd.bclj" \
  "$repo/native-core/src/native/body_c17.bclj" \
  "$repo/native-core/src/native/validation_corpus.bclj" \
  "$here/fixture.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

core_records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages obligations fold_c17 simd body_c17 validation_corpus \
  c17_fail_closed; do
  generated="$scratch/out/native/$module.clj"
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$generated"
  awk -v import="(import '[native.core $core_records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$generated" >"$generated.tmp"
  mv "$generated.tmp" "$generated"
done

bb -cp "$scratch/out" -e '
(require (quote native.c17-fail-closed))
(when-not native.c17-fail-closed/all-cases-pass?
  (throw (ex-info "C17 fail-closed validation failed"
           {:supported native.c17-fail-closed/supported-program-succeeds?
            :abi native.c17-fail-closed/unsupported-symbol-rejected?
            :optional native.c17-fail-closed/malformed-optional-rejected?
            :map-get native.c17-fail-closed/malformed-map-get-rejected?
            :checked-layout native.c17-fail-closed/malformed-checked-result-rejected?
            :checked-operation native.c17-fail-closed/checked-bounds-rejected?})))
(print native.c17-fail-closed/report)'
