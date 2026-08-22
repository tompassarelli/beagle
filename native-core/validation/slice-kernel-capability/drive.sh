#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-}"
store_checkout="$("$repo/native-core/validation/store-checkout.sh")"
types_file="$store_checkout/src/store/types.bgl"
kernel_file="$store_checkout/src/store/kernel.bgl"
probe_file="$here/host_capability_probe.bgl"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-kernel-capability.XXXXXX")"
[[ -n "$art" ]] || art="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-kernel-capability: $*" >&2
  exit 1
}

for command in bb jq rg sha256sum; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done
for source in "$types_file" "$kernel_file" "$probe_file"; do
  [[ -f "$source" ]] || die "source is unavailable: $source"
done
mkdir -p "$art" "$scratch/generated"

"$repo/bin/beagle-ast" --module-root "store/src=$store_checkout/src" \
  "$types_file" >"$scratch/types.ast.json"
"$repo/bin/beagle-ast" --module-root "store/src=$store_checkout/src" \
  "$kernel_file" >"$scratch/kernel.ast.json"
"$repo/bin/beagle-ast" --module-root "store/src=$store_checkout/src" \
  "$probe_file" >"$scratch/probe.ast.json"
types_logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
  "$scratch/types.ast.json")"
kernel_logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
  "$scratch/kernel.ast.json")"
probe_logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
  "$scratch/probe.ast.json")"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/types.ast.json=$types_logical" \
  --input "$scratch/kernel.ast.json=$kernel_logical" \
  --input "$scratch/probe.ast.json=$probe_logical" \
  --output "$scratch/generated/kernel_capability.facts" \
  --include-defs

{
  printf '%s  %s\n' "$(sha256sum "$types_file" | cut -d' ' -f1)" "$types_logical"
  printf '%s  %s\n' "$(sha256sum "$kernel_file" | cut -d' ' -f1)" "$kernel_logical"
  printf '%s  %s\n' "$(sha256sum "$probe_file" | cut -d' ' -f1)" "$probe_logical"
} >"$scratch/generated/source.sha256"

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
  "$here/host_capability_slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations simd c11 slice fold_c17 body_c17 body_slice qbe host_capability_slice; do
  [[ -f "$scratch/out/native/$module.clj" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$module.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
  mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"
done

bb -cp "$scratch/out" -e "
(require 'native.host-capability-slice)
(spit \"$scratch/generated/report.txt\"
  (native.host-capability-slice/emit-slice!
    \"$scratch/generated/kernel_capability.facts\"
    \"$scratch/generated\"
    \"native-kernel-capability-v0\"
    \"$kernel_logical\"))"

report="$scratch/generated/report.txt"
if [[ "${NATIVE_SLICE_SOURCE_ID_PROOF:-0}" == 1 ]]; then
  rg -Fx 'stage source-freeze ACCEPTED' "$report" >/dev/null
  printf 'slice-kernel-capability: source-id proof PASS types=%s kernel=%s probe=%s\n' \
    "$types_logical" "$kernel_logical" "$probe_logical"
  exit 0
fi
for line in \
  'stage source-freeze ACCEPTED' \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native PENDING' \
  'source-modules 3' \
  'source-imports 3' \
  'materialize REFUSED native lowering incomplete' \
  'qbe REFUSED native lowering incomplete'; do
  if ! rg -Fx "$line" "$report" >/dev/null; then
    cat "$report" >&2
    die "report is missing: $line"
  fi
done
for function in getenv getenv-present? getenv-length monotonic-now; do
  rg -n "^lowered fn_[0-9]+ ${function//\?/\\?} " "$report" >/dev/null \
    || die "host function is absent from the lowering frontier: $function"
done
for artifact in module_0.h module_0.c function_map.h; do
  [[ ! -e "$scratch/generated/$artifact" ]] \
    || die "pending Native lowering emitted $artifact"
done

generated_names=(kernel_capability.facts source.sha256 report.txt)
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

cat "$report"
publish_results
echo "slice-kernel-capability: pending lowering refused without artifacts"
