#!/usr/bin/env bash
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-parse-double.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-parse-double: $*" >&2
  exit 1
}

for command in awk bb cmp gcc rg; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done

clang_bin="$(command -v clang || true)"
if [[ -z "$clang_bin" ]]; then
  clang_bin="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null \
    | sort -V | tail -1)"
fi
[[ -n "$clang_bin" ]] || die "clang is required for the second C frontend"

"$repo/bin/beagle" check --agent \
  "$here/fixture.bgl" "$here/managed_fixture.bclj"
"$repo/bin/beagle-ast" "$here/fixture.bgl" >"$scratch/fixture.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/fixture.ast.json=native-core/validation/slice-parse-double/fixture.bgl" \
  --output "$scratch/fixture.facts" --include-defs

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
  "$repo/native-core/src/native/qbe.bclj" \
  "$repo/native-core/src/native/body_slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations simd c11 slice fold_c17 body_c17 qbe body_slice; do
  target="$scratch/out/native/$module.clj"
  [[ -f "$target" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$target"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$target" >"$target.tmp"
  mv "$target.tmp" "$target"
done

bb -cp "$scratch/out" -e "
(require 'native.body-slice)
(spit \"$scratch/report.txt\"
  (native.body-slice/emit-dual-slice! \"$scratch/fixture.facts\"
    \"native.parse-double\"
    \"native-core/validation/slice-parse-double/fixture.bgl\"
    \"$scratch\" \"native-slice-parse-double-v0\" \"parse-value\" 1 \"$abi\"))"

cat "$scratch/report.txt"
for line in \
  'stage source-freeze ACCEPTED' \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native COMPLETE' \
  'materialize OK module_0.h module_0.c' \
  'qbe-stage typed-to-native COMPLETE' \
  'qbe-selected-function parse-value' \
  "qbe-materialize REFUSED native program uses a shape outside the QBE materializer's slice"; do
  rg -Fx "$line" "$scratch/report.txt" >/dev/null \
    || die "report is missing: $line"
done
if rg -n '^pending ' "$scratch/report.txt" >/dev/null; then
  rg -n '^pending ' "$scratch/report.txt" >&2
  die "the parse-double projection reported pending functions"
fi

obligations=(valid-ssa exhaustive-matches closed-layouts checked-arithmetic legal-abi discharged-tokens bounded-effects epoch-soundness leak-freedom)
for obligation in "${obligations[@]}"; do
  rg -Fx "obligation-projection PASS $obligation" "$scratch/report.txt" >/dev/null \
    || die "validator did not pass: $obligation"
done
[[ "$(rg -c '^obligation-projection PASS ' "$scratch/report.txt")" -eq 10 ]] \
  || die "report did not contain exactly ten passing validators"

function_index() {
  local name="$1"
  awk -v name="$name" \
    '$1 == "lowered" && $3 == name { sub(/^fn_/, "", $2); print $2 }' \
    "$scratch/report.txt"
}

parse_index="$(function_index parse-value)"
present_index="$(function_index parsed?)"
bits_index="$(function_index parsed-bits)"
for entry in "$parse_index" "$present_index" "$bits_index"; do
  [[ "$entry" =~ ^[0-9]+$ ]] || die "failed to resolve all generated functions"
done

{
  echo '#ifndef NATIVE_PARSE_DOUBLE_FUNCTION_MAP_H'
  echo '#define NATIVE_PARSE_DOUBLE_FUNCTION_MAP_H'
  echo
  printf '#define PARSED_FN native_m0_fn_%s\n' "$present_index"
  printf '#define PARSED_BITS_FN native_m0_fn_%s\n' "$bits_index"
  echo
  echo '#endif'
} >"$scratch/function_map.h"

mkdir -p "$scratch/managed/native"
"$repo/bin/beagle-build" "$here/managed_fixture.bclj" \
  "$scratch/managed/native/parse_double_managed.clj" >/dev/null
bb -cp "$scratch/managed" \
  "$here/managed_runner.clj" "$here/corpus.tsv" >"$scratch/managed.out"

cp "$here/main.c" "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" \
  "$repo/native-core/shim/native_unicode15_data.h" "$scratch/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror -frounding-math)
rounding_modes=(nearest upward downward towardzero)

run_compiler() {
  local compiler="$1"
  local name="$2"
  local mode

  (
    cd "$scratch"
    "$compiler" "${strict[@]}" -o "probe_$name" \
      module_0.c native_shim.c main.c -lm
  )
  for mode in "${rounding_modes[@]}"; do
    "$scratch/probe_$name" "$here/corpus.tsv" "$mode" \
      >"$scratch/$name-$mode.out"
    cmp -s "$scratch/$name-$mode.out" "$scratch/managed.out" \
      || die "$name/$mode output differs from managed execution"
  done
}

run_compiler gcc gcc
run_compiler "$clang_bin" clang

case_count="$(wc -l <"$here/corpus.tsv")"
echo "slice-parse-double: managed + strict GCC/Clang parity PASS ($case_count cases)"
echo "slice-parse-double: FE_TONEAREST/UPWARD/DOWNWARD/TOWARDZERO parity PASS"
echo "slice-parse-double: nine Native obligations PASS; deterministic QBE refusal PASS"
