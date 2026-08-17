#!/usr/bin/env bash
# Proves the complete store.kernel-classify native program against its current
# managed execution through full C17 and a direct QBE projection.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-}"
store_checkout="$("$repo/native-core/validation/store-checkout.sh")"
source_file="$store_checkout/src/store/kernel_classify.bgl"
managed_out="$store_checkout/out"
probe_file="$here/kernel_classify_probe.bgl"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-kernel-classify.XXXXXX")"
[[ -n "$art" ]] || art="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-kernel-classify: $*" >&2
  exit 1
}

for command in bb cmp gcc jq rg sha256sum; do
  command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
done
[[ -f "$source_file" ]] || die "source is unavailable: $source_file"
[[ -f "$probe_file" ]] || die "probe is unavailable: $probe_file"
mkdir -p "$art" "$scratch/generated"

"$repo/bin/beagle-ast" "$source_file" >"$scratch/kernel.ast.json"
"$repo/bin/beagle-ast" "$probe_file" >"$scratch/probe.ast.json"
source_logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
  "$scratch/kernel.ast.json")"
probe_logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
  "$scratch/probe.ast.json")"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/kernel.ast.json=$source_logical" \
  --input "$scratch/probe.ast.json=$probe_logical" \
  --output "$scratch/generated/kernel_classify.facts" \
  --include-defs

source_digest="$(sha256sum "$source_file" | cut -d' ' -f1)"
probe_digest="$(sha256sum "$probe_file" | cut -d' ' -f1)"
corpus_digest="$(sha256sum "$here/corpus.tsv" | cut -d' ' -f1)"
runner_digest="$(sha256sum "$here/managed_runner.clj" | cut -d' ' -f1)"
dual_runner_digest="$(sha256sum "$here/dual_main.c" | cut -d' ' -f1)"
{
  printf '%s  %s\n' "$source_digest" "$source_logical"
  printf '%s  %s\n' "$probe_digest" "$probe_logical"
  printf '%s  %s\n' "$corpus_digest" 'beagle:native-core/validation/slice-kernel-classify/corpus.tsv'
  printf '%s  %s\n' "$runner_digest" 'managed-runner'
  printf '%s  %s\n' "$dual_runner_digest" 'qbe-c17-dual-runner'
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
  "$repo/native-core/src/native/qbe.bclj" \
  "$repo/native-core/src/native/body_slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,200p' "$scratch/build.log" >&2
    exit 1
  }

# Imported record patterns need the provider classes referred and imported in
# the generated Clojure until the emitter qualifies cross-module patterns.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations simd c11 slice fold_c17 body_c17 qbe body_slice; do
  [[ -f "$scratch/out/native/$module.clj" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$module.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
  mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"
done

bb -cp "$scratch/out" -e "
(require 'native.body-slice)
(spit \"$scratch/generated/report.txt\"
  (native.body-slice/emit-dual-slice!
    \"$scratch/generated/kernel_classify.facts\"
    \"store.kernel-classify\"
    \"$source_logical\"
    \"$scratch/generated\"
    \"native-kernel-classify-v0\"
    \"delivery-trigger?\"
    1
    \"$abi\"))"

report="$scratch/generated/report.txt"
if [[ "${NATIVE_SLICE_SOURCE_ID_PROOF:-0}" == 1 ]]; then
  rg -Fx 'stage source-freeze ACCEPTED' "$report" >/dev/null
  printf 'slice-kernel-classify: source-id proof PASS source=%s probe=%s\n' \
    "$source_logical" "$probe_logical"
  exit 0
fi
for line in \
  'stage source-freeze ACCEPTED' \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native COMPLETE' \
  'source-modules 2' \
  'source-imports 2' \
  'program-functions 19' \
  'program-abis 19' \
  'materialize OK module_0.h module_0.c' \
  'qbe-stage typed-to-native COMPLETE' \
  'qbe-selected-function delivery-trigger?' \
  'qbe-program-functions 1' \
  'qbe-program-abis 1' \
  'qbe-materialize OK module_1.ssa'; do
  rg -Fx "$line" "$report" >/dev/null || die "report is missing: $line"
done
if rg -n '^pending ' "$report" >/dev/null; then
  rg -n '^pending ' "$report" >&2
  die "the complete module reported pending functions"
fi

obligations=(valid-ssa exhaustive-matches closed-layouts checked-arithmetic legal-abi discharged-tokens bounded-effects epoch-soundness leak-freedom)
for obligation in "${obligations[@]}"; do
  rg -Fx "obligation-projection PASS $obligation" "$report" >/dev/null \
    || die "validator did not pass: $obligation"
  rg -Fx "qbe-obligation PASS $obligation" "$report" >/dev/null \
    || die "QBE projection validator did not pass: $obligation"
done
[[ "$(rg -c '^obligation-projection PASS ' "$report")" -eq 10 ]] \
  || die "report did not contain exactly ten passing validators"
[[ "$(rg -c '^qbe-obligation PASS ' "$report")" -eq 10 ]] \
  || die "report did not contain exactly ten passing QBE validators"
[[ "$(rg -c '^lowered fn_[0-9]+ ' "$report")" -eq 19 ]] \
  || die "report did not contain exactly nineteen lowered functions"

map="$scratch/generated/function_map.h"
printf '%s\n' \
  '#ifndef NATIVE_KERNEL_CLASSIFY_FUNCTION_MAP_H' \
  '#define NATIVE_KERNEL_CLASSIFY_FUNCTION_MAP_H' \
  '' >"$map"
while IFS='|' read -r macro function_name; do
  index="$(awk -v name="$function_name" \
    '$1 == "lowered" && $3 == name { sub(/^fn_/, "", $2); print $2 }' "$report")"
  [[ "$index" =~ ^[0-9]+$ ]] || die "missing or duplicate lowered function: $function_name"
  printf '#define %s native_m0_fn_%s\n' "$macro" "$index" >>"$map"
done <<'FUNCTIONS'
KC_STRIP_AT|strip-at
KC_HAS_WHITESPACE|has-whitespace?
KC_REF_SHAPE|ref-shape?
KC_VEC_MEMBER|vec-member?
KC_EMOJI_SINGLE|emoji-single?
KC_CONFIGURED_SINGLE|configured-single?
KC_META_SINGLE_SEED|meta-single-seed?
KC_SINGLE_EFF|single-eff?
KC_KEY_OF_GROUP|key-of-group
KC_KEY_OF_TRIPLE|key-of-triple
KC_NORMALIZE_REF_VALUE|normalize-ref-value
KC_LEASE_INVALID|lease-invalid
KC_LEASE_SUBJECT|lease-subject
KC_LEASE_ENCODE|lease-encode
KC_LEASE_DECODE|lease-decode
KC_DELIVERY_TRIGGER|delivery-trigger?
KC_OBSERVED_FALLBACK_SINGLE|observed-fallback-single
KC_OBSERVED_KEY_SEP|observed-key-sep
KC_OBSERVED_LEASE_SCHEMA_LINES|observed-lease-schema-lines
FUNCTIONS
printf '\n#endif\n' >>"$map"

generated_names=(kernel_classify.facts source.sha256 report.txt function_map.h module_0.h module_0.c module_1.ssa)
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

if [[ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]]; then
  publish_results
  exit 0
fi

[[ -d "$managed_out" ]] || die "managed projection is unavailable: $managed_out"
bb -cp "$managed_out" \
  "$here/managed_runner.clj" "$here/corpus.tsv" >"$scratch/managed-current.out"
[[ "$(wc -l <"$scratch/managed-current.out")" -eq 139 ]] \
  || die "managed execution produced the wrong case count"

build="$scratch/c"
mkdir -p "$build"
cp "$scratch/generated/module_0.h" "$scratch/generated/module_0.c" \
  "$scratch/generated/function_map.h" "$here/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
(cd "$build" && gcc "${strict[@]}" -o probe_gcc module_0.c native_shim.c main.c)
"$build/probe_gcc" "$here/corpus.tsv" >"$scratch/gcc.out"

clang_bin="$(command -v clang || true)"
if [[ -z "$clang_bin" ]]; then
  clang_bin="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
fi
[[ -n "$clang_bin" ]] || die "clang is required for the second C frontend"
(cd "$build" && "$clang_bin" "${strict[@]}" -o probe_clang module_0.c native_shim.c main.c)
"$build/probe_clang" "$here/corpus.tsv" >"$scratch/clang.out"

for output in "$scratch/gcc.out" "$scratch/clang.out"; do
  cmp -s "$output" "$scratch/managed-current.out" \
    || die "native output differs from current managed execution: $output"
done

find_qbe() {
  if [[ -n "${QBE_BIN:-}" ]]; then
    [[ -x "$QBE_BIN" ]] && printf '%s\n' "$QBE_BIN"
    return
  fi
  if command -v qbe >/dev/null 2>&1; then
    command -v qbe
    return
  fi
  local candidate
  candidate="$(find /nix/store -maxdepth 3 -type f -path '*-qbe-*/bin/qbe' \
    | sort -V | tail -1)"
  [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

qbe_bin="$(find_qbe || true)"
[[ -n "$qbe_bin" ]] || die "qbe is required to assemble the direct projection"

cp "$scratch/generated/module_1.ssa" "$here/dual_main.c" "$build/"
"$qbe_bin" "$build/module_1.ssa" >"$build/module_1.s"
(cd "$build" && gcc "${strict[@]}" -c module_0.c -o module_0.o)
(cd "$build" && gcc "${strict[@]}" -c native_shim.c -o native_shim.o)
(cd "$build" && gcc "${strict[@]}" -c dual_main.c -o dual_main.o)
(cd "$build" && gcc -c module_1.s -o module_1.o)
(cd "$build" && gcc module_0.o module_1.o native_shim.o dual_main.o -o probe_dual)

delivery_inputs=(to target from '' targeted)
"$build/probe_dual" "${delivery_inputs[@]}" >"$scratch/dual.out"
awk -F '\t' '$1 == "deliveryTrigger" { print $3 }' "$scratch/managed-current.out" \
  >"$scratch/delivery-managed.out"
[[ "$(wc -l <"$scratch/delivery-managed.out")" -eq 5 ]] \
  || die "managed delivery case count differs"
cut -f1 "$scratch/dual.out" >"$scratch/delivery-c17.out"
cut -f2 "$scratch/dual.out" >"$scratch/delivery-qbe.out"
cmp -s "$scratch/delivery-c17.out" "$scratch/delivery-managed.out" \
  || die "C17 delivery projection differs from managed execution"
cmp -s "$scratch/delivery-qbe.out" "$scratch/delivery-managed.out" \
  || die "QBE delivery projection differs from managed execution"

for index in "${!delivery_inputs[@]}"; do
  result="$(sed -n "$((index + 1))p" "$scratch/delivery-managed.out")"
  [[ "$result" == 1 ]] && rendered=true || rendered=false
  printf 'slice-kernel-classify: delivery-trigger?("%s") managed=%s c17=%s qbe=%s\n' \
    "${delivery_inputs[index]}" "$rendered" "$rendered" "$rendered"
done

echo "slice-kernel-classify: gcc strict compile + 77 cases + 3 globals PASS"
echo "slice-kernel-classify: clang strict compile + 77 cases + 3 globals PASS"
echo "slice-kernel-classify: direct QBE assemble + link + 5 managed parity cases PASS"
publish_results
