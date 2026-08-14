#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-}"
main_file="$here/main_fixture.bgl"
variadic_file="$here/variadic_entry_refusal.bgl"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-main-capability.XXXXXX")"
[[ -n "$art" ]] || art="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-main-capability: $*" >&2
  exit 1
}

for command in bb cmp gcc rg sha256sum; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done
[[ -f "$main_file" ]] || die "source is unavailable: $main_file"
[[ -f "$variadic_file" ]] || die "source is unavailable: $variadic_file"
mkdir -p "$art" "$scratch/generated"

"$repo/bin/beagle-ast" "$main_file" >"$scratch/main.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/main.ast.json=native-core/validation/slice-main-capability/main_fixture.bgl" \
  --output "$scratch/generated/main_capability.facts" \
  --include-defs

sha256sum "$main_file" \
  | sed 's#  .*#  native-core/validation/slice-main-capability/main_fixture.bgl#' \
  >"$scratch/generated/source.sha256"

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
  "$repo/native-core/src/native/body_slice.bclj" \
  "$repo/native-core/src/native/qbe.bclj" \
  "$here/main_capability_slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations simd c11 slice fold_c17 body_c17 body_slice qbe main_capability_slice; do
  [[ -f "$scratch/out/native/$module.clj" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$module.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
  mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"
done

bb -cp "$scratch/out" -e "
(require 'native.main-capability-slice)
(spit \"$scratch/generated/report.txt\"
  (native.main-capability-slice/emit-slice!
    \"$scratch/generated/main_capability.facts\"
    \"$scratch/generated\"
    \"native-main-capability-v0\"))"

report="$scratch/generated/report.txt"
for line in \
  'stage source-freeze ACCEPTED' \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native COMPLETE' \
  'source-modules 1' \
  'source-imports 0' \
  'program-functions 1' \
  'program-abis 2' \
  'materialize OK module_0.h module_0.c' \
  'qbe REFUSED QBE stdout extern ABI is unsupported: Text handles have no QBE call representation'; do
  if ! rg -Fx "$line" "$report" >/dev/null; then
    cat "$report" >&2
    die "report is missing: $line"
  fi
done
rg -n '^lowered fn_[0-9]+ -main ' "$report" >/dev/null \
  || die "fram.main/-main did not lower"
obligations=(valid-ssa exhaustive-matches closed-layouts checked-arithmetic legal-abi discharged-tokens bounded-effects epoch-soundness leak-freedom)
for obligation in "${obligations[@]}"; do
  rg -Fx "obligation-main PASS $obligation" "$report" >/dev/null \
    || die "validator did not pass: $obligation"
done
[[ "$(rg -c '^obligation-main PASS ' "$report")" -eq 10 ]] \
  || die "report did not contain exactly ten passing validators"

index="$(awk '$1 == "lowered" && $3 == "-main" { sub(/^fn_/, "", $2); print $2 }' "$report")"
[[ "$index" =~ ^[0-9]+$ ]] || die "missing or duplicate lowered function: -main"
map="$scratch/generated/function_map.h"
printf '%s\n' \
  '#ifndef NATIVE_MAIN_CAPABILITY_FUNCTION_MAP_H' \
  '#define NATIVE_MAIN_CAPABILITY_FUNCTION_MAP_H' \
  '' \
  "#define FRAM_MAIN native_m0_fn_$index" \
  '' \
  '#endif' >"$map"

generated_names=(main_capability.facts source.sha256 report.txt function_map.h module_0.h module_0.c)
for name in "${generated_names[@]}"; do
  [[ -f "$scratch/generated/$name" ]] || die "materializer omitted $name"
done


publish_results() {
  local name
  mkdir -p "$art"
  for name in "${generated_names[@]}"; do
    cp -- "$scratch/generated/$name" "$art/$name"
  done
}

set +e
"$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/variadic-refusal" \
  --entry native.main-capability-variadic-refusal/-main \
  "$variadic_file" >"$scratch/variadic.stdout" 2>"$scratch/variadic.stderr"
variadic_status=$?
set -e
[[ $variadic_status -ne 0 ]] || die "variadic Native entry unexpectedly built"
rg -F 'entry native.main-capability-variadic-refusal/-main must not have a rest parameter' \
  "$scratch/variadic.stderr" >/dev/null \
  || die "variadic Native entry refusal changed"
[[ ! -e "$scratch/variadic-refusal/report.txt" ]] \
  || die "failed variadic build published a partial report"

cat "$report"
if [[ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]]; then
  publish_results
  exit 0
fi

build="$scratch/c"
mkdir -p "$build"
cp "$scratch/generated/module_0.h" "$scratch/generated/module_0.c" \
  "$scratch/generated/function_map.h" "$here/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
(cd "$build" && gcc "${strict[@]}" -o probe_gcc \
  module_0.c native_shim.c main.c)
(cd "$build" && ./probe_gcc >actual.out)
expected='fram usage: validate | tell <subject> <slot> <value> | retract <subject> <slot> <value> (alias: untell) | query <edn> | selfcheck --deep'
[[ "$(<"$build/actual.out")" == "$expected" ]] \
  || die "gcc binary stdout did not match fram.main"
echo "slice-main-capability: gcc $(gcc -dumpversion) strict compile + run ok"

if command -v clang >/dev/null 2>&1; then
  (cd "$build" && clang "${strict[@]}" -o probe_clang \
    module_0.c native_shim.c main.c)
  (cd "$build" && ./probe_clang >actual-clang.out)
  cmp "$build/actual.out" "$build/actual-clang.out" \
    || die "clang binary stdout differed from gcc"
  echo "slice-main-capability: clang $(clang -dumpversion | head -1) compile + run ok"
fi

publish_results
