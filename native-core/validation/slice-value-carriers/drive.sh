#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-value-carriers.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-value-carriers: $*" >&2
  exit 1
}

for command in rg; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done

"$repo/bin/beagle" check --agent "$here/fixture.bgl"

"$repo/bin/beagle-ast" "$here/fixture.bgl" >"$scratch/fixture.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input \
  "$scratch/fixture.ast.json=native-core/validation/slice-value-carriers/fixture.bgl" \
  --output "$scratch/fixture.facts" --include-defs

mkdir -p "$scratch/artifacts"
source "$repo/bin/_beagle-racket"
base_compiled="${NATIVE_SLICE_BASE_COMPILED:-}"
if [[ -n "$base_compiled" ]]; then
  [[ -f "$base_compiled/native/core.clj" ]] \
    || die "base compiler projection omitted native/core.clj: $base_compiled"
  cp -a "$base_compiled" "$scratch/compiled"

  declare -a compiler_pids=()
  declare -a compiler_names=(lower body_c17 slice_value_carriers_slice)
  declare -a compiler_sources=(
    "$repo/native-core/src/native/lower.bclj"
    "$repo/native-core/src/native/body_c17.bclj"
    "$here/carrier_slice.bclj"
  )
  for index in "${!compiler_sources[@]}"; do
    name="${compiler_names[$index]}"
    mkdir -p "$scratch/$name"
    "$RACKET" "$repo/native-core/bin/run-bounded.rkt" 180 5 -- \
      "$repo/bin/beagle-build-all" \
      --module-root native-core/src="$repo/native-core/src" \
      "${compiler_sources[$index]}" \
      --out "$scratch/$name" >"$scratch/$name.log" 2>&1 &
    compiler_pids+=("$!")
  done

  compiler_failed=0
  for index in "${!compiler_pids[@]}"; do
    if ! wait "${compiler_pids[$index]}"; then
      sed -n '1,240p' "$scratch/${compiler_names[$index]}.log" >&2
      compiler_failed=1
    fi
  done
  (( compiler_failed == 0 )) || exit 1
  for name in "${compiler_names[@]}"; do
    cp "$scratch/$name/native/$name.clj" "$scratch/compiled/native/$name.clj"
  done
else
  "$RACKET" "$repo/native-core/bin/run-bounded.rkt" 180 5 -- \
    "$repo/bin/beagle-build-all" \
    "$repo/native-core/src/native/core.bclj" \
    "$repo/native-core/src/native/stages.bclj" \
    "$repo/native-core/src/native/lower.bclj" \
    "$repo/native-core/src/native/obligations.bclj" \
    "$repo/native-core/src/native/simd.bclj" \
    "$repo/native-core/src/native/c11.bclj" \
    "$repo/native-core/src/native/slice.bclj" \
    "$repo/native-core/src/native/fold_c17.bclj" \
    "$repo/native-core/src/native/body_c17.bclj" \
    "$here/carrier_slice.bclj" \
    --out "$scratch/compiled" >"$scratch/compiler.log" 2>&1 || {
      sed -n '1,240p' "$scratch/compiler.log" >&2
      exit 1
    }
fi

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/compiled/native/core.clj" | tr '\n' ' ')"
for module in \
  stages lower obligations c11 slice fold_c17 body_c17 \
  slice_value_carriers_slice; do
  generated="$scratch/compiled/native/$module.clj"
  [[ -f "$generated" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$generated"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$generated" >"$generated.tmp"
  mv "$generated.tmp" "$generated"
done

bb -cp "$scratch/compiled" -e "
(require 'native.slice-value-carriers-slice)
(spit \"$scratch/artifacts/report.txt\"
  (native.slice-value-carriers-slice/emit-fixture!
    \"$scratch/fixture.facts\" \"$scratch/artifacts\"))"

report="$scratch/artifacts/report.txt"
for expected in \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native COMPLETE' \
  'materialize OK module_0.h module_0.c'; do
  rg -Fx "$expected" "$report" >/dev/null \
    || die "report is missing: $expected"
done

if rg -q '^pending |REJECTED|REFUSED' "$report"; then
  cat "$report" >&2
  die "focused Native Core report retained a rejection"
fi

for function in \
  empty-vector-any vector-any empty-map-any map-any empty-set-any set-any \
  parsed-float-any; do
  rg -Fx "lowered ${function}" "$report" \
    || die "lowered function is missing: $function"
done

rejection_shapes=(
  'TODO-NATIVE-EMPTY-VECTOR-LITERAL: an empty literal names no element type'
  'TODO-NATIVE-EMPTY-VECTOR-LITERAL: the contextual type is not an exact native vector type'
  'TODO-NATIVE-EMPTY-MAP-LITERAL: an empty literal names no key or value type'
  'TODO-NATIVE-EMPTY-MAP-LITERAL: the contextual type is not an exact native map type'
  'TODO-NATIVE-VECTOR-LITERAL-TYPE: the module declares no vector of this element type'
  'TODO-NATIVE-SET-LITERAL-TYPE: the module declares no set of this element type'
  'TODO-NATIVE-PARSE-F64-TYPE: parse-double needs a nullable Float in the source program'
)
for shape in "${rejection_shapes[@]}"; do
  if rg -F "$shape" "$report" >/dev/null; then
    die "report retained S1 rejection: $shape"
  fi
done

cat "$report"
echo "slice-value-carriers: recursive Vec/Map/Set Any carriers and nullable Float PASS"
