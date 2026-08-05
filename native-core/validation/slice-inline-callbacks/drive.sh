#!/usr/bin/env bash
# Exercises eager inline callbacks, lexical captures, and function-boundary refusals.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-inline-callbacks.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

for command in awk bb clojure gcc rg; do
  command -v "$command" >/dev/null || {
    echo "drive.sh: required command is unavailable: $command" >&2
    exit 1
  }
done

find_clang() {
  if command -v clang >/dev/null 2>&1; then
    command -v clang
    return 0
  fi
  local candidate
  candidate="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null \
    | sort -V | tail -1)"
  [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
if [[ -z "$clang_bin" ]]; then
  echo "drive.sh: required command is unavailable: clang" >&2
  exit 1
fi

mkdir -p "$scratch/out" "$scratch/art" "$scratch/refusal-art" "$scratch/c"

"$repo/bin/beagle-ast" "$here/inline_callbacks.bclj" \
  >"$scratch/inline_callbacks.ast.json"
"$repo/bin/beagle-ast" "$here/inline_callback_refusals.bclj" \
  >"$scratch/inline_callback_refusals.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/inline_callbacks.ast.json=beagle:native-core/validation/slice-inline-callbacks/inline_callbacks.bclj" \
  --output "$scratch/inline_callbacks.facts"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/inline_callback_refusals.ast.json=beagle:native-core/validation/slice-inline-callbacks/inline_callback_refusals.bclj" \
  --output "$scratch/inline_callback_refusals.facts"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bgl" \
  "$repo/native-core/src/native/worlds.bgl" \
  "$repo/native-core/src/native/lower.bgl" \
  "$repo/native-core/src/native/obligations.bgl" \
  "$repo/native-core/src/native/c11.bgl" \
  "$repo/native-core/src/native/slice.bgl" \
  "$repo/native-core/src/native/fold_c17.bgl" \
  "$repo/native-core/src/native/body_c17.bgl" \
  "$repo/native-core/src/native/qbe.bgl" \
  "$repo/native-core/src/native/body_slice.bgl" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,200p' "$scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in worlds lower obligations c11 slice fold_c17 body_c17 qbe body_slice; do
  generated="$scratch/out/native/$module.clj"
  [[ -f "$generated" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$generated"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$generated" >"$generated.tmp"
  mv "$generated.tmp" "$generated"
done

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.body-slice)
(spit \"$scratch/report.txt\"
  (native.body-slice/emit-dual-slice!
    \"$scratch/inline_callbacks.facts\"
    \"native.inline-callbacks\"
    \"beagle:native-core/validation/slice-inline-callbacks/inline_callbacks.bclj\"
    \"$scratch/art\" \"native-inline-callbacks-v0\"
    \"captured-reduce\" 0))
(spit \"$scratch/refusal-report.txt\"
  (native.body-slice/emit-slice!
    \"$scratch/inline_callback_refusals.facts\"
    \"native.inline-callback-refusals\"
    \"beagle:native-core/validation/slice-inline-callbacks/inline_callback_refusals.bclj\"
    \"$scratch/refusal-art\" \"native-inline-callback-refusals-v0\"))"

report="$scratch/report.txt"
refusal_report="$scratch/refusal-report.txt"
cat "$report" "$refusal_report"

for name in captured-reduce captured-map captured-filter captured-every? \
    captured-some? shadowed-map-parameter nested-captures \
    contextual-reduce-any contextual-map-any insertion-order-set-reduce; do
  awk -v name="$name" \
    '$1 == "lowered" && $3 == name { found = 1 } END { exit !found }' \
    "$report" || {
    echo "drive.sh: $name did not lower" >&2
    exit 1
  }
done

for obligation in valid-ssa exhaustive-matches closed-layouts \
    checked-arithmetic legal-abi discharged-tokens bounded-effects; do
  rg -q "^obligation-projection PASS $obligation$" "$report" || {
    echo "drive.sh: missing passing obligation: $obligation" >&2
    exit 1
  }
done

rg -q '^stage typed-to-native COMPLETE$' "$report"
rg -q '^materialize OK module_0.h module_0.c$' "$report"
rg -q '^qbe-selected-function captured-reduce$' "$report"
rg -Fq "qbe-materialize REFUSED native world uses a shape outside the QBE materializer's slice" \
  "$report"
rg -q 'TODO-NATIVE-VECTOR-HOF-CALLBACK: mapv requires an anonymous function literal' \
  "$refusal_report"
rg -q 'TODO-NATIVE-RECUR-OUTSIDE-LOOP: recur has no enclosing loop header' \
  "$refusal_report"

function_index() {
  local name="$1"
  awk -v name="$name" \
    '$1 == "lowered" && $3 == name { sub(/^fn_/, "", $2); print $2 }' \
    "$report"
}

captured_reduce="$(function_index captured-reduce)"
captured_map="$(function_index captured-map)"
captured_filter="$(function_index captured-filter)"
captured_every="$(function_index captured-every?)"
captured_some="$(function_index captured-some?)"
shadowed_map="$(function_index shadowed-map-parameter)"
nested_captures="$(function_index nested-captures)"
contextual_reduce="$(function_index contextual-reduce-any)"
contextual_map="$(function_index contextual-map-any)"
set_reduce="$(function_index insertion-order-set-reduce)"

for index in "$captured_reduce" "$captured_map" "$captured_filter" \
    "$captured_every" "$captured_some" "$shadowed_map" "$nested_captures" \
    "$contextual_reduce" "$contextual_map" "$set_reduce"; do
  [[ -n "$index" ]] || {
    echo "drive.sh: could not resolve a materialized function index" >&2
    exit 1
  }
done

cp "$scratch/art/module_0.h" "$scratch/art/module_0.c" "$here/main.c" \
  "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$scratch/c/"

definitions=(
  "-DCAPTURED_REDUCE_FN=native_m0_fn_$captured_reduce"
  "-DCAPTURED_MAP_FN=native_m0_fn_$captured_map"
  "-DCAPTURED_FILTER_FN=native_m0_fn_$captured_filter"
  "-DCAPTURED_EVERY_FN=native_m0_fn_$captured_every"
  "-DCAPTURED_SOME_FN=native_m0_fn_$captured_some"
  "-DSHADOWED_MAP_FN=native_m0_fn_$shadowed_map"
  "-DNESTED_CAPTURES_FN=native_m0_fn_$nested_captures"
  "-DCONTEXTUAL_REDUCE_FN=native_m0_fn_$contextual_reduce"
  "-DCONTEXTUAL_MAP_FN=native_m0_fn_$contextual_map"
  "-DSET_REDUCE_FN=native_m0_fn_$set_reduce"
)
strict=(-std=c17 -pedantic -Wall -Wextra -Werror)

(
  cd "$scratch/c"
  gcc "${strict[@]}" "${definitions[@]}" -o probe_gcc \
    module_0.c native_shim.c main.c
  ./probe_gcc
)

(
  cd "$scratch/c"
  "$clang_bin" "${strict[@]}" "${definitions[@]}" -o probe_clang \
    module_0.c native_shim.c main.c
  ./probe_clang
)

echo "inline-callbacks: captures, boundary coercion, insertion-order Set reduction, strict C17, and QBE refusal PASS"
