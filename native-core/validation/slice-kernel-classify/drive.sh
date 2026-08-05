#!/usr/bin/env bash
# Proves the complete fram.kernel-classify Native World against its managed
# oracle through full C17 and a direct QBE projection of delivery-trigger?.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
source_file="${FRAM_KERNEL_CLASSIFY:-/home/tom/code/fram/main/src/fram/kernel_classify.bclj}"
probe_file="$here/kernel_classify_probe.bclj"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-kernel-classify.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-kernel-classify: $*" >&2
  exit 1
}

for command in bb clojure cmp gcc rg sha256sum; do
  command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
done
[[ -f "$source_file" ]] || die "source is unavailable: $source_file"
[[ -f "$probe_file" ]] || die "probe is unavailable: $probe_file"
mkdir -p "$art" "$scratch/generated"

"$repo/bin/beagle-ast" "$source_file" >"$scratch/kernel.ast.json"
"$repo/bin/beagle-ast" "$probe_file" >"$scratch/probe.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/kernel.ast.json=fram:src/fram/kernel_classify.bclj" \
  --input "$scratch/probe.ast.json=beagle:native-core/validation/slice-kernel-classify/kernel_classify_probe.bclj" \
  --output "$scratch/generated/kernel_classify.facts" \
  --include-defs

source_digest="$(sha256sum "$source_file" | cut -d' ' -f1)"
probe_digest="$(sha256sum "$probe_file" | cut -d' ' -f1)"
corpus_digest="$(sha256sum "$here/corpus.tsv" | cut -d' ' -f1)"
oracle_digest="$(sha256sum "$here/managed.out" | cut -d' ' -f1)"
runner_digest="$(sha256sum "$here/managed_runner.clj" | cut -d' ' -f1)"
dual_runner_digest="$(sha256sum "$here/dual_main.c" | cut -d' ' -f1)"
{
  printf '%s  %s\n' "$source_digest" 'fram:src/fram/kernel_classify.bclj'
  printf '%s  %s\n' "$probe_digest" 'beagle:native-core/validation/slice-kernel-classify/kernel_classify_probe.bclj'
  printf '%s  %s\n' "$corpus_digest" 'beagle:native-core/validation/slice-kernel-classify/corpus.tsv'
  printf '%s  %s\n' "$oracle_digest" 'managed-oracle-output'
  printf '%s  %s\n' "$runner_digest" 'managed-oracle-runner'
  printf '%s  %s\n' "$dual_runner_digest" 'qbe-c17-dual-runner'
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
  "$repo/native-core/src/native/qbe.bclj" \
  "$repo/native-core/src/native/body_slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,200p' "$scratch/build.log" >&2
    exit 1
  }

# Imported record patterns need the provider classes referred and imported in
# the generated Clojure until the emitter qualifies cross-module patterns.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in worlds lower obligations c11 slice fold_c17 body_c17 qbe body_slice; do
  [[ -f "$scratch/out/native/$module.clj" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$module.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
  mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"
done

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.body-slice)
(spit \"$scratch/generated/report.txt\"
  (native.body-slice/emit-dual-slice!
    \"$scratch/generated/kernel_classify.facts\"
    \"fram.kernel-classify\"
    \"fram:src/fram/kernel_classify.bclj\"
    \"$scratch/generated\"
    \"native-kernel-classify-v0\"
    \"delivery-trigger?\"
    1))"

report="$scratch/generated/report.txt"
for line in \
  'stage source-seal ACCEPTED' \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native COMPLETE' \
  'source-modules 2' \
  'source-imports 2' \
  'world-functions 19' \
  'world-abis 19' \
  'materialize OK module_0.h module_0.c' \
  'qbe-stage typed-to-native COMPLETE' \
  'qbe-selected-function delivery-trigger?' \
  'qbe-world-functions 1' \
  'qbe-world-abis 1' \
  'qbe-materialize OK module_1.ssa'; do
  rg -Fx "$line" "$report" >/dev/null || die "report is missing: $line"
done
if rg -n '^pending ' "$report" >/dev/null; then
  rg -n '^pending ' "$report" >&2
  die "the complete module reported pending functions"
fi

obligations=(valid-ssa exhaustive-matches closed-layouts checked-arithmetic legal-abi discharged-tokens bounded-effects)
for obligation in "${obligations[@]}"; do
  rg -Fx "obligation-projection PASS $obligation" "$report" >/dev/null \
    || die "validator did not pass: $obligation"
  rg -Fx "qbe-obligation PASS $obligation" "$report" >/dev/null \
    || die "QBE projection validator did not pass: $obligation"
done
[[ "$(rg -c '^obligation-projection PASS ' "$report")" -eq 7 ]] \
  || die "report did not contain exactly seven passing validators"
[[ "$(rg -c '^qbe-obligation PASS ' "$report")" -eq 7 ]] \
  || die "report did not contain exactly seven passing QBE validators"
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

publish_generated() {
  local name="$1"
  if [[ -f "$here/$name" ]] && ! cmp -s "$scratch/generated/$name" "$here/$name"; then
    diff -u "$here/$name" "$scratch/generated/$name" >&2 || true
    die "generated artifact drifted: $name"
  fi
  cp "$scratch/generated/$name" "$art/$name"
}

for name in kernel_classify.facts source.sha256 report.txt function_map.h module_0.h module_0.c module_1.ssa; do
  [[ -f "$scratch/generated/$name" ]] || die "materializer omitted $name"
  publish_generated "$name"
done

cat "$report"

if [[ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]]; then
  exit 0
fi

[[ "$(wc -l <"$here/managed.out")" -eq 139 ]] || die "managed oracle line count drifted"
[[ "$(wc -c <"$here/managed.out")" -eq 3591 ]] || die "managed oracle byte count drifted"
[[ "$oracle_digest" == '2bab2e7d00496f24ee9ff852c0eed177b6e3ab1c64fdeb7ca39271b1cfb5feef' ]] \
  || die "managed oracle digest drifted"

if [[ -d /home/tom/code/fram/main/out ]]; then
  clojure -Sdeps '{:paths ["/home/tom/code/fram/main/out"]}' -M \
    "$here/managed_runner.clj" "$here/corpus.tsv" >"$scratch/managed-fresh.out"
  cmp -s "$scratch/managed-fresh.out" "$here/managed.out" \
    || die "fresh managed execution differs from the committed oracle"
fi

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
  cmp -s "$output" "$here/managed.out" || die "native output differs from managed oracle: $output"
  [[ "$(wc -l <"$output")" -eq 139 ]] || die "native output line count differs"
  [[ "$(wc -c <"$output")" -eq 3591 ]] || die "native output byte count differs"
  [[ "$(sha256sum "$output" | cut -d' ' -f1)" == "$oracle_digest" ]] \
    || die "native output digest differs"
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
awk -F '\t' '$1 == "deliveryTrigger" { print $3 }' "$here/managed.out" \
  >"$scratch/delivery-managed.out"
[[ "$(wc -l <"$scratch/delivery-managed.out")" -eq 5 ]] \
  || die "managed oracle delivery case count drifted"
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
echo "slice-kernel-classify: lines=139 bytes=3591 sha256=$oracle_digest"
