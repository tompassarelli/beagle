#!/usr/bin/env bash
# Drive union coercion plus dynamic Any value semantics through native C17/QBE.
# The gate owns active-branch equality/hash/compare, Map/Set persistent and
# transient behavior, compile-time unsupported-union refusals, and exact traps
# for unsupported values, malformed handles, wrong tags, and reference/vector
# cycles. It reuses slice-bodies' AST-to-facts projection unchanged.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
src="$here/fixture.bclj"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-union.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

"$repo/bin/beagle-ast" "$src" >"$scratch/fixture.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  "$scratch/fixture.ast.json" \
  "$scratch/fixture.facts"
if [[ -f "$art/fixture.facts" ]] && ! cmp -s "$scratch/fixture.facts" "$art/fixture.facts"; then
  echo "drive.sh: regenerated projection differs from the committed fixture.facts" >&2
  exit 1
fi
cp "$scratch/fixture.facts" "$art/fixture.facts"
sha256sum "$src" | cut -d' ' -f1 >"$art/source.sha256"

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
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || { sed -n '1,200p' "$scratch/build.log" >&2; exit 1; }

# A cross-module `match` on an imported union emits an unqualified variant name;
# re-exporting native.core's records into each consumer namespace is the repo's
# standing workaround until the emitter qualifies them.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for m in stages lower obligations c11 slice fold_c17 body_c17 qbe body_slice; do
  [ -f "$scratch/out/native/$m.clj" ] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$scratch/out/native/$m.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$m.clj" >"$scratch/out/native/$m.clj.tmp"
  mv "$scratch/out/native/$m.clj.tmp" "$scratch/out/native/$m.clj"
done

bb -cp "$scratch/out" -e "
(require 'native.body-slice)
(spit \"$art/report.txt\"
  (native.body-slice/emit-dual-slice! \"$scratch/fixture.facts\" \"fixture.union\"
    \"native-core/validation/slice-union/fixture.bclj\" \"$art\"
    \"native-slice-union-v0\" \"numeric-int-double-less?\" 2 \"$abi\"))"

cat "$art/report.txt"
grep -Fq "lowered fn_44 vector-value? " "$art/report.txt"
grep -Fq "lowered fn_45 vector-probe " "$art/report.txt"
grep -Fq "lowered fn_46 int-vector? " "$art/report.txt"
grep -Fq "lowered fn_47 text-ends-with? " "$art/report.txt"
grep -Fq "lowered fn_48 maybe-int-if " "$art/report.txt"
grep -Fq "lowered fn_49 maybe-int-when " "$art/report.txt"
grep -Fq "lowered fn_50 empty-any-map " "$art/report.txt"
grep -Fq "lowered fn_51 any-map-contains? " "$art/report.txt"
grep -Fq "lowered fn_52 any-map-assoc " "$art/report.txt"
grep -Fq "lowered fn_53 empty-any-set " "$art/report.txt"
grep -Fq "lowered fn_54 any-set-contains? " "$art/report.txt"
grep -Fq "lowered fn_55 any-set-conj " "$art/report.txt"
grep -Fq "lowered fn_56 any-map-count " "$art/report.txt"
grep -Fq "lowered fn_57 any-map-value " "$art/report.txt"
grep -Fq "lowered fn_58 any-map-dissoc " "$art/report.txt"
grep -Fq "lowered fn_59 any-set-count " "$art/report.txt"
grep -Fq "lowered fn_60 any-set-disj " "$art/report.txt"
grep -Fq "lowered fn_61 transient-any-map! " "$art/report.txt"
grep -Fq "lowered fn_62 transient-any-set! " "$art/report.txt"
grep -Fq "lowered fn_63 any-equal-int? " "$art/report.txt"
grep -Fq "lowered fn_64 int-equal-any? " "$art/report.txt"
grep -Fq "lowered fn_65 any-not-equal-int? " "$art/report.txt"

refusal="$scratch/mixed-value-refusal"
mkdir -p "$refusal"
"$repo/bin/beagle-ast" "$here/mixed_value_refusal.bclj" \
  >"$refusal/fixture.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  "$refusal/fixture.ast.json" \
  "$refusal/fixture.facts"
bb -cp "$scratch/out" -e "
(require 'native.body-slice)
(spit \"$refusal/report.txt\"
  (native.body-slice/emit-slice!
    \"$refusal/fixture.facts\" \"fixture.union-refusal\"
    \"native-core/validation/slice-union/mixed_value_refusal.bclj\"
    \"$refusal\" \"native-slice-union-refusal-v0\" \"$abi\"))"
cat "$refusal/report.txt"
grep -Fq "TODO-NATIVE-EQUALITY-UNION-VALUE-SEMANTICS" \
  "$refusal/report.txt" || {
  echo "drive.sh: mixed union refusal diagnostic missing" >&2
  exit 1
}
for function in map-or-int-equal? set-or-int-equal? cell-or-int-equal?; do
  grep -Fq "[$function]" "$refusal/report.txt" || {
    echo "drive.sh: mixed union refusal missing function: $function" >&2
    exit 1
  }
done
grep -Fq "TODO-NATIVE-FUNCTION-ABI: function-or-int-equal?" \
  "$refusal/report.txt" || {
  echo "drive.sh: function-bearing union ABI refusal missing" >&2
  exit 1
}

if [ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]; then
  exit 0
fi

build="$scratch/c"
mkdir -p "$build"
cp "$art/module_0.h" "$art/module_0.c" "$art/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"

any_type="$(sed -nE \
  's/^(native_m0_type_[0-9]+) native_m0_fn_1\(.*/\1/p' \
  "$art/module_0.h")"
nil_type="$(sed -nE \
  's/^(native_m0_type_[0-9]+) native_m0_fn_15\(.*/\1/p' \
  "$art/module_0.h")"
pair_type="$(sed -nE \
  's/^(native_m0_type_[0-9]+) native_m0_fn_7\(.*/\1/p' \
  "$art/module_0.h")"
if [[ -z "$any_type" || -z "$nil_type" || -z "$pair_type" ]]; then
  echo "drive.sh: could not resolve generated Any, Nil, and Pair types" >&2
  exit 1
fi
type_definitions=(
  "-DSLICE_ANY_TYPE=$any_type"
  "-DSLICE_NIL_TYPE=$nil_type"
  "-DSLICE_PAIR_TYPE=$pair_type")

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)

expect_abort() {
  local probe="$1"
  local operation="$2"
  local description="$3"
  local status

  if bash -c '
      cd "$1" || exit 125
      ulimit -c 0
      "./$2" "$3" >/dev/null 2>&1
      observed=$?
      exit "$observed"
    ' _ "$build" "$probe" "$operation" 2>/dev/null; then
    status=0
  else
    status=$?
  fi
  if [[ $status -ne 134 ]]; then
    echo "drive.sh: $description (expected abort 134, observed $status)" >&2
    exit 1
  fi
}

( cd "$build" && gcc "${strict[@]}" "${type_definitions[@]}" \
    -o probe_gcc module_0.c native_shim.c main.c )
( cd "$build" && ./probe_gcc )
expect_abort probe_gcc mismatch "the mismatched union tag did not trap"
expect_abort probe_gcc null "the null record reference did not trap"
expect_abort probe_gcc double "double accepted a non-numeric union tag"
for operation in \
    ue uh uc oe oh oc ce ch cc le lc xe xc ye yc za zb zn vv ve vh vc \
    we wh wc ie ih ic pe ph pc \
    g q a s j k r tm ts; do
  expect_abort probe_gcc "$operation" \
    "dynamic unsupported value semantics did not trap: $operation"
done
echo "drive.sh: gcc $(gcc -dumpversion) strict compile + run + mismatch/null/double/dynamic-value traps ok"

find_clang() {
  if command -v clang >/dev/null 2>&1; then command -v clang; return 0; fi
  local candidate
  candidate="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  [ -n "$candidate" ] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
if [ -n "$clang_bin" ]; then
  ( cd "$build" && "$clang_bin" "${strict[@]}" "${type_definitions[@]}" \
      -o probe_clang module_0.c native_shim.c main.c )
  ( cd "$build" && ./probe_clang )
  expect_abort probe_clang mismatch \
    "clang build did not trap on the mismatched union tag"
  expect_abort probe_clang null \
    "clang build did not trap on the null record reference"
  expect_abort probe_clang double \
    "clang build did not trap on an invalid double operand"
  for operation in \
      ue uh uc oe oh oc ce ch cc le lc xe xc ye yc za zb zn vv ve vh vc \
      we wh wc ie ih ic pe ph pc \
      g q a s j k r tm ts; do
    expect_abort probe_clang "$operation" \
      "clang dynamic unsupported value semantics did not trap: $operation"
  done
  echo "drive.sh: clang $("$clang_bin" -dumpversion) compile + run + mismatch/null/double/dynamic-value traps ok"
else
  echo "drive.sh: clang not found — second frontend NOT exercised" >&2
fi
