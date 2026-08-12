#!/usr/bin/env bash
# Exercises ordered non-looping expression bodies through native program and C17.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-do-sequence.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

for command in awk bb gcc rg; do
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
  candidate="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
if [[ -z "$clang_bin" ]]; then
  echo "drive.sh: required command is unavailable: clang" >&2
  exit 1
fi

bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$here/sequence.ast.json=beagle:native-core/validation/slice-do-sequence/sequence.ast.json" \
  --output "$scratch/sequence.facts"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
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

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations c11 slice fold_c17 body_c17 qbe body_slice; do
  [[ -f "$scratch/out/native/$module.clj" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$module.clj"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
  mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"
done

bb -cp "$scratch/out" -e "
(require 'native.body-slice)
(spit \"$scratch/report.txt\"
  (native.body-slice/emit-slice! \"$scratch/sequence.facts\"
    \"native.do-sequence-validation\"
    \"beagle:native-core/validation/slice-do-sequence/sequence.ast.json\"
    \"$scratch\" \"native-do-sequence-v0\" \"$abi\"))"

report="$scratch/report.txt"
cat "$report"
for expected in \
  'lowered fn_[0-9]+ body-last ' \
  'lowered fn_[0-9]+ do-last ' \
  'lowered fn_[0-9]+ do-first-traps ' \
  'lowered fn_[0-9]+ do-ref-last ' \
  'lowered fn_[0-9]+ do-branch-last ' \
  'pending TODO-NATIVE-FUNCTION-BODY: TODO-NATIVE-DO-EMPTY: empty do is outside the native slice \[do-empty\]' \
  'pending TODO-NATIVE-FUNCTION-BODY: TODO-NATIVE-DOSEQ-CLAUSES: v0 accepts exactly one binding clause \[do-doseq\]' \
  'materialize OK module_0.h module_0.c'; do
  rg -q "$expected" "$report" || {
    echo "drive.sh: report omitted expected evidence: $expected" >&2
    exit 1
  }
done

function_index() {
  local name="$1"
  awk -v name="$name" \
    '$1 == "lowered" && $3 == name { sub(/^fn_/, "", $2); print $2 }' \
    "$report"
}

body_last="$(function_index body-last)"
do_last="$(function_index do-last)"
do_first_traps="$(function_index do-first-traps)"
do_ref_last="$(function_index do-ref-last)"
do_branch_last="$(function_index do-branch-last)"
if [[ -z "$body_last" || -z "$do_last" || -z "$do_first_traps" ||
      -z "$do_ref_last" || -z "$do_branch_last" ]]; then
  echo "drive.sh: failed to resolve materialized function indices" >&2
  exit 1
fi

cp "$here/main.c" "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$scratch/"

definitions=(
  "-DBODY_LAST_FN=native_m0_fn_$body_last"
  "-DDO_LAST_FN=native_m0_fn_$do_last"
  "-DDO_FIRST_TRAPS_FN=native_m0_fn_$do_first_traps"
  "-DDO_REF_LAST_FN=native_m0_fn_$do_ref_last"
  "-DDO_BRANCH_LAST_FN=native_m0_fn_$do_branch_last"
)
strict=(-std=c17 -pedantic -Wall -Wextra -Werror)

(
  cd "$scratch"
  gcc "${strict[@]}" "${definitions[@]}" -o probe_gcc \
    module_0.c native_shim.c main.c
  ./probe_gcc
  if (ulimit -c 0 && ./probe_gcc trap) 2>/dev/null; then
    echo "drive.sh: GCC probe skipped the discarded first expression" >&2
    exit 1
  fi
)

(
  cd "$scratch"
  "$clang_bin" "${strict[@]}" "${definitions[@]}" -o probe_clang \
    module_0.c native_shim.c main.c
  ./probe_clang
  if (ulimit -c 0 && ./probe_clang trap) 2>/dev/null; then
    echo "drive.sh: Clang probe skipped the discarded first expression" >&2
    exit 1
  fi
)

echo "do-sequence: profile facts, named negatives, strict GCC+Clang, and runtime order PASS"
