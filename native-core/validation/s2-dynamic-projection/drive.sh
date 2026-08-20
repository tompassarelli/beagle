#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-s2-dynamic-projection.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "s2-dynamic-projection: $*" >&2
  exit 1
}

timeout --foreground 30s "$repo/bin/beagle" check --agent "$here/fixture.bgl"

for target in clj js nix; do
  fixture="$here/hosted_fixture.b${target}"
  if [[ "$target" == clj ]]; then
    fixture="$here/hosted_fixture.bclj"
  fi
  timeout --foreground 60s "$repo/bin/beagle" build \
    --target "$target" "$fixture" "$scratch/$target"
done

base_compiled="${NATIVE_SLICE_BASE_COMPILED:-}"
if [[ -n "$base_compiled" ]]; then
  [[ -f "$base_compiled/native/core.clj" ]] \
    || die "base compiler projection omitted native/core.clj: $base_compiled"
  cp -a "$base_compiled" "$scratch/compiled"
  source "$repo/bin/_beagle-racket"

  declare -a compiler_pids=()
  declare -a compiler_names=(
    core lower obligations c11 fold_c17 body_c17 qbe unit_compile
  )
  declare -a compiler_sources=(
    "$repo/native-core/src/native/core.bclj"
    "$repo/native-core/src/native/lower.bclj"
    "$repo/native-core/src/native/obligations.bclj"
    "$repo/native-core/src/native/c11.bclj"
    "$repo/native-core/src/native/fold_c17.bclj"
    "$repo/native-core/src/native/body_c17.bclj"
    "$repo/native-core/src/native/qbe.bclj"
    "$repo/native-core/src/native/unit_compile.bclj"
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

  records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
    "$scratch/compiled/native/core.clj" | tr '\n' ' ')"
  for name in lower obligations c11 fold_c17 body_c17 qbe; do
    generated="$scratch/compiled/native/$name.clj"
    sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
      "$generated"
    awk -v import="(import '[native.core $records])" \
      '!seen && /^$/ { print import; seen = 1 } { print }' \
      "$generated" >"$generated.tmp"
    mv "$generated.tmp" "$generated"
  done
fi

native_env=()
if [[ -n "$base_compiled" ]]; then
  native_env+=("BEAGLE_CORE_COMPILED_OVERRIDE=$scratch/compiled")
fi
timeout --foreground 180s env "${native_env[@]}" "$repo/bin/beagle-native-exe" \
  --out "$scratch/s2-dynamic-projection-fixture" \
  --artifacts "$scratch/artifacts" \
  --entry native.s2-dynamic-projection/main! \
  -- "$here/fixture.bgl"

timeout --foreground 10s "$scratch/s2-dynamic-projection-fixture"
report="$scratch/artifacts/report.txt"
for expected in \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native COMPLETE' \
  'materialize-c17 OK module_0.h module_0.c' \
  'result PASS'; do
  rg -Fx "$expected" "$report" >/dev/null \
    || die "report is missing: $expected"
done

for function in \
  direct-map short-map direct-vector short-vector direct-set short-set \
  direct-text short-text cond-projection unguarded-map nullable-map \
  unguarded-vector unguarded-text unguarded-str unguarded-map-tail \
  unguarded-vector-tail unguarded-set-tail unguarded-text-tail \
  unguarded-regex carrier-vector carrier-count reduce-dynamic-texts \
  step-counter! main!; do
  rg -q "^lowered fn_[0-9]+ ${function} " "$report" \
    || die "lowered function is missing: $function"
done

if rg -q 'TODO-NATIVE-(COLLECTION|GET|NTH|SUBVEC|ASSOC|MAP-KEYS|MAP-VALUES|CONTAINS|DOSEQ|REDUCE|VEC|INTO|TEXT|REST|POP|REVERSE|CONCAT|DISJ|SUBS|REGEX)' \
  "$report"; then
  cat "$report" >&2
  die "a C2 rejection shape remains"
fi

echo "s2-dynamic-projection: all hosted emitters and native execution PASS"
