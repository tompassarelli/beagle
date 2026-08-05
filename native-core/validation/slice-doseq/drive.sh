#!/usr/bin/env bash
# Exercises the restricted closed-Vec doseq slice through Native World and C17.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-doseq.XXXXXX")"
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

mkdir -p "$scratch/out" "$scratch/art" "$scratch/c"

"$repo/bin/beagle-ast" "$here/doseq.bclj" >"$scratch/doseq.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/doseq.ast.json=beagle:native-core/validation/slice-doseq/doseq.bclj" \
  --output "$scratch/doseq.facts"

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
    sed -n '1,240p' "$scratch/build.log" >&2
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
  (native.body-slice/emit-slice! \"$scratch/doseq.facts\"
    \"native.doseq\"
    \"beagle:native-core/validation/slice-doseq/doseq.bclj\"
    \"$scratch/art\" \"native-doseq-v0\"))"

report="$scratch/report.txt"
cat "$report"

for name in ordered-indexes drive; do
  awk -v name="$name" \
    '$1 == "lowered" && $3 == name { found = 1 } END { exit !found }' \
    "$report" || {
    echo "drive.sh: $name did not lower" >&2
    exit 1
  }
done

for expected in \
  'TODO-NATIVE-DOSEQ-COLLECTION: v0 iterates one closed native Vec \[dynamic-source\]' \
  'TODO-NATIVE-DOSEQ-BINDING-TYPE: the binding annotation does not match the Vec element type \[dynamic-binding\]' \
  'TODO-NATIVE-DOSEQ-BINDING: v0 needs one simple named binding \[destructured-binding\]' \
  'TODO-NATIVE-DOSEQ-BINDING-TYPE: the binding annotation does not match the Vec element type \[mismatched-binding\]' \
  'TODO-NATIVE-DOSEQ-CLAUSES: v0 accepts exactly one binding clause \[two-bindings\]' \
  'TODO-NATIVE-DOSEQ-MODIFIER: v0 accepts no :let, :when, or :while clause \[guarded\]' \
  'TODO-NATIVE-DOSEQ-BODY: v0 accepts exactly one body form \[two-body-forms\]'; do
  rg -q "$expected" "$report" || {
    echo "drive.sh: report omitted expected refusal: $expected" >&2
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

rg -q '^materialize OK module_0.h module_0.c$' "$report"
rg -q 'native_vec_length' "$scratch/art/module_0.c"
rg -q 'native_vec_at' "$scratch/art/module_0.c"

drive_index="$(awk '$1 == "lowered" && $3 == "drive" {
  sub(/^fn_/, "", $2); print $2
}' "$report")"
if [[ -z "$drive_index" ]]; then
  echo "drive.sh: failed to resolve the materialized driver index" >&2
  exit 1
fi

cp "$scratch/art/module_0.h" "$scratch/art/module_0.c" "$here/main.c" \
  "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$scratch/c/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
definition="-DDRIVE_FN=native_m0_fn_$drive_index"

run_compiler() {
  local compiler="$1"
  local output="$2"
  (
    cd "$scratch/c"
    "$compiler" "${strict[@]}" "$definition" -o "$output" \
      module_0.c native_shim.c main.c
    "./$output"
    if (ulimit -c 0 && "./$output" trap) 2>/dev/null; then
      echo "drive.sh: $compiler skipped the doseq back edge" >&2
      exit 1
    fi
  )
}

run_compiler gcc probe_gcc
run_compiler "$clang_bin" probe_clang

echo "doseq: closed Vec loop, ordered continuation, named refusals, and strict GCC+Clang PASS"
