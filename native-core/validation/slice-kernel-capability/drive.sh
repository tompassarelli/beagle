#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
types_file="${FRAM_TYPES:-/home/tom/code/fram/main/src/fram/types.bclj}"
kernel_file="${FRAM_KERNEL:-/home/tom/code/fram/main/src/fram/kernel.bclj}"
probe_file="$here/host_capability_probe.bclj"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-kernel-capability.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-kernel-capability: $*" >&2
  exit 1
}

for command in bb clojure cmp gcc rg sha256sum; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done
for source in "$types_file" "$kernel_file" "$probe_file"; do
  [[ -f "$source" ]] || die "source is unavailable: $source"
done
mkdir -p "$art" "$scratch/generated"

"$repo/bin/beagle-ast" "$types_file" >"$scratch/types.ast.json"
"$repo/bin/beagle-ast" "$kernel_file" >"$scratch/kernel.ast.json"
"$repo/bin/beagle-ast" "$probe_file" >"$scratch/probe.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/types.ast.json=fram:src/fram/types.bclj" \
  --input "$scratch/kernel.ast.json=fram:src/fram/kernel.bclj" \
  --input "$scratch/probe.ast.json=beagle:native-core/validation/slice-kernel-capability/host_capability_probe.bclj" \
  --output "$scratch/generated/kernel_capability.facts" \
  --include-defs

{
  sha256sum "$types_file" | sed 's#  .*#  fram:src/fram/types.bclj#'
  sha256sum "$kernel_file" | sed 's#  .*#  fram:src/fram/kernel.bclj#'
  sha256sum "$probe_file" | sed 's#  .*#  beagle:native-core/validation/slice-kernel-capability/host_capability_probe.bclj#'
} >"$scratch/generated/source.sha256"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/worlds.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  "$repo/native-core/src/native/fold_c17.bclj" \
  "$repo/native-core/src/native/body_c17.bclj" \
  "$repo/native-core/src/native/body_slice.bclj" \
  "$repo/native-core/src/native/qbe.bclj" \
  "$here/host_capability_slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in worlds lower obligations c11 slice fold_c17 body_c17 body_slice qbe host_capability_slice; do
  [[ -f "$scratch/out/native/$module.clj" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$module.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
  mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"
done

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.host-capability-slice)
(spit \"$scratch/generated/report.txt\"
  (native.host-capability-slice/emit-slice!
    \"$scratch/generated/kernel_capability.facts\"
    \"$scratch/generated\"
    \"native-kernel-capability-v0\"))"

report="$scratch/generated/report.txt"
for line in \
  'stage source-seal ACCEPTED' \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native PENDING' \
  'source-modules 3' \
  'source-imports 2' \
  'host-world-functions 4' \
  'host-world-abis 6' \
  'materialize OK module_0.h module_0.c' \
  'qbe REFUSED QBE monotonic clock extern ABI is unsupported: host clock reads have no QBE call representation'; do
  if ! rg -Fx "$line" "$report" >/dev/null; then
    cat "$report" >&2
    die "report is missing: $line"
  fi
done
for function in getenv getenv-present? getenv-length monotonic-now; do
  rg -n "^lowered fn_[0-9]+ ${function//\?/\\?} " "$report" >/dev/null \
    || die "host function did not lower: $function"
done
obligations=(valid-ssa exhaustive-matches closed-layouts checked-arithmetic legal-abi discharged-tokens bounded-effects)
for obligation in "${obligations[@]}"; do
  rg -Fx "obligation-host PASS $obligation" "$report" >/dev/null \
    || die "validator did not pass: $obligation"
done
[[ "$(rg -c '^obligation-host PASS ' "$report")" -eq 7 ]] \
  || die "report did not contain exactly seven passing validators"

map="$scratch/generated/function_map.h"
printf '%s\n' \
  '#ifndef NATIVE_HOST_CAPABILITY_FUNCTION_MAP_H' \
  '#define NATIVE_HOST_CAPABILITY_FUNCTION_MAP_H' \
  '' >"$map"
while IFS='|' read -r macro function_name; do
  index="$(awk -v name="$function_name" \
    '$1 == "lowered" && $3 == name { sub(/^fn_/, "", $2); print $2 }' "$report")"
  [[ "$index" =~ ^[0-9]+$ ]] || die "missing or duplicate lowered function: $function_name"
  printf '#define %s native_m0_fn_%s\n' "$macro" "$index" >>"$map"
done <<'FUNCTIONS'
HOST_GETENV|getenv
HOST_GETENV_PRESENT|getenv-present?
HOST_GETENV_LENGTH|getenv-length
HOST_MONOTONIC_NOW|monotonic-now
FUNCTIONS
printf '\n#endif\n' >>"$map"

publish_generated() {
  local name="$1"
  if [[ -f "$here/$name" ]] && ! cmp -s "$scratch/generated/$name" "$here/$name"; then
    diff -u "$here/$name" "$scratch/generated/$name" >&2 || true
    die "generated artifact drifted: $name"
  fi
  cp "$scratch/generated/$name" "$art/$name"
}

for name in kernel_capability.facts source.sha256 report.txt function_map.h module_0.h module_0.c; do
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
  "$scratch/generated/function_map.h" "$here/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
(cd "$build" && gcc "${strict[@]}" -o probe_gcc \
  module_0.c native_shim.c main.c)
(cd "$build" && BEAGLE_NATIVE_HOST_TEST=capability-value ./probe_gcc)
echo "slice-kernel-capability: gcc $(gcc -dumpversion) strict compile + run ok"

if command -v clang >/dev/null 2>&1; then
  (cd "$build" && clang "${strict[@]}" -o probe_clang \
    module_0.c native_shim.c main.c)
  (cd "$build" && BEAGLE_NATIVE_HOST_TEST=capability-value ./probe_clang)
  echo "slice-kernel-capability: clang $(clang -dumpversion | head -1) compile + run ok"
fi
