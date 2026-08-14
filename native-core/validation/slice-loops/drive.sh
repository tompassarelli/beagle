#!/usr/bin/env bash
# Drive loop/recur through the native pipeline: beagle-ast -> source facts ->
# frozen source program -> typed program -> native program (one SSA header block per
# loop, one back-edge Jump per recur) -> 7 obligations -> native.body-c17 ->
# gcc/clang -std=c17 -> probe main.
# Two programs: loops.bgl must pass all ten obligations; counted/ carries the
# fram counted shapes and refuses checked-arithmetic on its interim add-i64.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-loops.XXXXXX")"
[[ -n "$art" ]] || art="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT

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
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || { sed -n '1,200p' "$scratch/build.log" >&2; exit 1; }

# A cross-module `match` on an imported union emits an unqualified variant name;
# re-exporting native.core's records into each consumer namespace is the repo's
# standing workaround until the emitter qualifies them.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for m in stages lower obligations simd c11 slice fold_c17 body_c17 qbe body_slice; do
  [ -f "$scratch/out/native/$m.clj" ] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$scratch/out/native/$m.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$m.clj" >"$scratch/out/native/$m.clj.tmp"
  mv "$scratch/out/native/$m.clj.tmp" "$scratch/out/native/$m.clj"
done

emit_slice() {
  local src="$1" generated="$2" module="$3"
  local annotation="${4:-}" pending="${5:-}"
  local logical
  local -a projector_args
  mkdir -p "$generated"
  "$repo/bin/beagle-ast" "$src" >"$scratch/ast.json"
  logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
    "$scratch/ast.json")"
  projector_args=(--input "$scratch/ast.json=$logical" \
    --output "$generated/loops.facts")
  if [[ -n "$annotation" ]]; then
    projector_args+=(--native-op "$annotation")
  fi
  bb "$here/../slice-bodies/ast-facts.clj" "${projector_args[@]}"
  sha256sum "$src" | cut -d' ' -f1 >"$generated/source.sha256"
  bb -cp "$scratch/out" -e "
(require 'native.body-slice)
(spit \"$generated/report.txt\"
  (native.body-slice/emit-slice! \"$generated/loops.facts\" \"$module\"
    \"$logical\" \"$generated\" \"native-slice-loops-v0\" \"$abi\"))"
  cat "$generated/report.txt"
  if [ -z "$pending" ] && grep -q '^pending ' "$generated/report.txt"; then
    echo "drive.sh: a loop fixture function did not lower" >&2
    exit 1
  fi
}

# A probe main must never spell a generated type by its ordinal: the emitter
# numbers the type table in collection order, so an unrelated lowering change
# renumbers it. Read the ordinal back out of the emitted header instead, the
# same way validation/wasm32 resolves slice-union's types.
return_type_of() { # return_type_of <header> <fn-index>
  local header="$1" index="$2" name
  name="$(sed -nE "s/^(native_m0_type_[0-9]+) native_m0_fn_$index\(.*/\1/p" "$header")"
  [ -n "$name" ] || { echo "drive.sh: no return type for fn_$index in $header" >&2; exit 1; }
  printf '%s\n' "$name"
}

compile_and_run() {
  local generated="$1" main_file="$2" label="$3"; shift 3
  local build="$scratch/c-$label"
  mkdir -p "$build"
  cp "$generated/module_0.h" "$generated/module_0.c" "$build/"
  cp "$main_file" "$build/main.c"
  cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"
  ( cd "$build" && gcc -std=c17 -pedantic -Wall -Wextra -Werror "$@" \
      -o probe_gcc module_0.c native_shim.c main.c )
  ( cd "$build" && ./probe_gcc )
  echo "drive.sh: $label gcc $(gcc -dumpversion) strict compile + run ok"
  local clang_bin
  clang_bin="$(command -v clang 2>/dev/null || ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  if [ -n "$clang_bin" ]; then
    ( cd "$build" && "$clang_bin" -std=c17 -Werror "$@" -o probe_clang module_0.c native_shim.c main.c )
    ( cd "$build" && ./probe_clang )
    echo "drive.sh: $label clang $("$clang_bin" -dumpversion) compile + run ok"
  else
    echo "drive.sh: clang not found — second frontend NOT exercised" >&2
  fi
}

main_generated="$scratch/generated-main"
counted_generated="$scratch/generated-counted"
refusal_generated="$scratch/generated-refusals"

emit_slice "$here/loops.bgl" "$main_generated" "native.loops"
if grep -q '^obligation-projection FAIL' "$main_generated/report.txt"; then
  echo "drive.sh: loops.bgl must discharge all ten obligations" >&2
  exit 1
fi

emit_slice "$here/counted/loops_counted.bgl" "$counted_generated" \
  "native.loops-counted" "add-i64=checked-add-i64"
# the interim add-i64 primitive returns Int where the obligation wants an
# Outcome, so exactly this one refusal is expected until the arithmetic arm lands
expected_fail="obligation-projection FAIL checked-arithmetic"
if [ "$(grep -c '^obligation-projection FAIL' "$counted_generated/report.txt")" != "1" ] ||
   ! grep -qx "$expected_fail" "$counted_generated/report.txt"; then
  echo "drive.sh: counted/ obligations changed beyond the known checked-arithmetic refusal" >&2
  exit 1
fi

emit_slice "$here/refusals/refusals.bgl" "$refusal_generated" \
  "native.loops-refusals" "" allow-pending
for expected in \
  'TODO-NATIVE-RECUR-NON-TAIL.*\[non-tail\]' \
  'TODO-NATIVE-RECUR-OUTSIDE-LOOP.*\[outside-loop\]' \
  'TODO-NATIVE-RECUR-ARITY.*\[wrong-arity\]' \
  'TODO-NATIVE-RECUR-TYPES.*\[wrong-types\]' \
  'TODO-NATIVE-RECUR-NON-TAIL.*\[non-tail-do\]' \
  'TODO-NATIVE-RECUR-NON-TAIL.*\[non-tail-cond-test\]' \
  'TODO-NATIVE-RECUR-NON-TAIL.*\[through-try\]' \
  'TODO-NATIVE-RECUR-NON-TAIL.*\[nested-init\]' \
  'TODO-NATIVE-RECUR-ARITY.*\[nested-wrong-target\]'; do
  grep -q "$expected" "$refusal_generated/report.txt" ||
    { echo "drive.sh: refusals/ omitted expected evidence: $expected" >&2; exit 1; }
done
publish_results() {
  mkdir -p "$art" "$art/counted" "$art/refusals"
  cp -- "$main_generated/loops.facts" "$main_generated/source.sha256" \
    "$main_generated/report.txt" "$main_generated/module_0.h" \
    "$main_generated/module_0.c" "$art/"
  cp -- "$counted_generated/loops.facts" "$counted_generated/source.sha256" \
    "$counted_generated/report.txt" "$counted_generated/module_0.h" \
    "$counted_generated/module_0.c" "$art/counted/"
  cp -- "$refusal_generated/loops.facts" "$refusal_generated/source.sha256" \
    "$refusal_generated/report.txt" "$art/refusals/"
}

if [ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]; then
  publish_results
  exit 0
fi

compile_and_run "$main_generated" "$here/main.c" loops
compile_and_run "$counted_generated" "$here/counted/main.c" counted \
  "-DCOUNTED_PAIR_TYPE=$(return_type_of "$counted_generated/module_0.h" 4)"

publish_results
