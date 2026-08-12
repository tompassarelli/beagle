#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
# Upstream fram sources are vendored under native-core/validation/upstream/fram
# (its MANIFEST records the fram revision and digests); a FRAM_* override still
# points a run at a live checkout. The default is beagle-only ON PURPOSE: a gate
# must not be a function of another repository's working tree.
main_file="${FRAM_MAIN:-$repo/native-core/validation/upstream/fram/src/fram/main.bclj}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-main-capability.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-main-capability: $*" >&2
  exit 1
}

for command in bb clojure cmp gcc rg sha256sum; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done
[[ -f "$main_file" ]] || die "source is unavailable: $main_file"
mkdir -p "$art" "$scratch/generated"

"$repo/bin/beagle-ast" "$main_file" >"$scratch/main.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/main.ast.json=fram:src/fram/main.bclj" \
  --output "$scratch/generated/main_capability.facts" \
  --include-defs

sha256sum "$main_file" \
  | sed 's#  .*#  fram:src/fram/main.bclj#' \
  >"$scratch/generated/source.sha256"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
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
for module in stages lower obligations c11 slice fold_c17 body_c17 body_slice qbe main_capability_slice; do
  [[ -f "$scratch/out/native/$module.clj" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$module.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
  mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"
done

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
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
[[ "$(rg -c '^obligation-main PASS ' "$report")" -eq 9 ]] \
  || die "report did not contain exactly nine passing validators"

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

publish_generated() {
  local name="$1"
  if [[ -f "$here/$name" ]] && ! cmp -s "$scratch/generated/$name" "$here/$name"; then
    diff -u "$here/$name" "$scratch/generated/$name" >&2 || true
    die "generated artifact drifted: $name"
  fi
  cp "$scratch/generated/$name" "$art/$name"
}

for name in main_capability.facts source.sha256 report.txt function_map.h module_0.h module_0.c; do
  [[ -f "$scratch/generated/$name" ]] || die "materializer omitted $name"
  publish_generated "$name"
done

cat "$report"
if [[ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]]; then
  exit 0
fi

build="$scratch/c"
mkdir -p "$build"
cp "$scratch/generated/module_0.h" "$scratch/generated/module_0.c" \
  "$scratch/generated/function_map.h" "$here/main.c" "$here/expected.out" "$build/"
cp "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
(cd "$build" && gcc "${strict[@]}" -o probe_gcc \
  module_0.c native_shim.c main.c)
(cd "$build" && ./probe_gcc >actual.out)
cmp "$build/expected.out" "$build/actual.out" \
  || die "gcc binary stdout did not match exact fram.main output"
echo "slice-main-capability: gcc $(gcc -dumpversion) strict compile + run ok"

if command -v clang >/dev/null 2>&1; then
  (cd "$build" && clang "${strict[@]}" -o probe_clang \
    module_0.c native_shim.c main.c)
  (cd "$build" && ./probe_clang >actual-clang.out)
  cmp "$build/expected.out" "$build/actual-clang.out" \
    || die "clang binary stdout did not match exact fram.main output"
  echo "slice-main-capability: clang $(clang -dumpversion | head -1) compile + run ok"
fi
