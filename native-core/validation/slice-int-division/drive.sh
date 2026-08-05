#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-int-division.XXXXXX")"
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
  candidate="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
if [[ -z "$clang_bin" ]]; then
  echo "drive.sh: required command is unavailable: clang" >&2
  exit 1
fi

"$repo/bin/beagle-ast" "$here/fixture.bclj" >"$scratch/fixture.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  "$scratch/fixture.ast.json=beagle:native-core/validation/slice-int-division/fixture.bclj" \
  "$scratch/fixture.facts"
"$repo/bin/beagle-ast" "$here/ratio_refusal.bclj" >"$scratch/ratio.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  "$scratch/ratio.ast.json=beagle:native-core/validation/slice-int-division/ratio_refusal.bclj" \
  "$scratch/ratio.facts"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bgl" \
  "$repo/native-core/src/native/worlds.bgl" \
  "$repo/native-core/src/native/lower.bgl" \
  "$repo/native-core/src/native/obligations.bgl" \
  "$repo/native-core/src/native/c11.bgl" \
  "$repo/native-core/src/native/slice.bgl" \
  "$repo/native-core/src/native/fold_c17.bgl" \
  "$repo/native-core/src/native/body_c17.bgl" \
  "$repo/native-core/src/native/body_slice.bgl" \
  "$repo/native-core/src/native/qbe.bgl" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in worlds lower obligations c11 slice fold_c17 body_c17 body_slice qbe; do
  target="$scratch/out/native/$module.clj"
  [[ -f "$target" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$target"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$target" >"$target.tmp"
  mv "$target.tmp" "$target"
done

mkdir -p "$scratch/ratio"
clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.body-slice)
(spit \"$scratch/report.txt\"
  (native.body-slice/emit-dual-slice! \"$scratch/fixture.facts\"
    \"native.int-division\"
    \"beagle:native-core/validation/slice-int-division/fixture.bclj\"
    \"$scratch\" \"native-int-division-v0\" \"quot-int\" 0))
(spit \"$scratch/ratio-report.txt\"
  (native.body-slice/emit-slice! \"$scratch/ratio.facts\"
    \"native.ratio-refusal\"
    \"beagle:native-core/validation/slice-int-division/ratio_refusal.bclj\"
    \"$scratch/ratio\" \"native-int-division-v0\"))"

cat "$scratch/report.txt"
rg -q '^stage typed-to-native COMPLETE$' "$scratch/report.txt"
rg -q '^materialize OK module_0.h module_0.c$' "$scratch/report.txt"
rg -q '^qbe-materialize REFUSED QBE checked integer division is unsupported: quot$' \
  "$scratch/report.txt"
if rg -q '^obligation-projection FAIL' "$scratch/report.txt"; then
  echo "drive.sh: division projection failed a Native obligation" >&2
  exit 1
fi
rg -q 'TODO-NATIVE-DIVISION-/: ratio division is outside native Int semantics' \
  "$scratch/ratio-report.txt"

function_index() {
  local name="$1"
  awk -v name="$name" \
    '$1 == "lowered" && $3 == name { sub(/^fn_/, "", $2); print $2 }' \
    "$scratch/report.txt"
}

quot_index="$(function_index quot-int)"
rem_index="$(function_index rem-int)"
mod_index="$(function_index mod-int)"
add_index="$(function_index variadic-add)"
multiply_index="$(function_index variadic-multiply)"
negate_index="$(function_index unary-negate)"
keyword_index="$(function_index literal-keyword-equal?)"
if [[ -z "$quot_index" || -z "$rem_index" || -z "$mod_index" ||
      -z "$add_index" || -z "$multiply_index" || -z "$negate_index" ||
      -z "$keyword_index" ]]; then
  echo "drive.sh: failed to resolve integer function indices" >&2
  exit 1
fi

mkdir -p "$scratch/managed/native"
"$repo/bin/beagle-build" "$here/fixture.bclj" \
  "$scratch/managed/native/int_division.clj" >/dev/null
clojure -Sdeps "{:paths [\"$scratch/managed\"]}" -M -e "
(require 'native.int-division)
(assert (= -2 (native.int-division/quot-int -7 3)))
(assert (= -1 (native.int-division/rem-int -7 3)))
(assert (= 2 (native.int-division/mod-int -7 3)))
(assert (= 9 (native.int-division/variadic-add 2 3 4)))
(assert (= -24 (native.int-division/variadic-multiply -2 3 4)))
(assert (= -7 (native.int-division/unary-negate 7)))
(assert (native.int-division/literal-keyword-equal?))
(assert (= Long/MIN_VALUE
  (native.int-division/quot-int Long/MIN_VALUE -1)))
(assert (= 0 (native.int-division/rem-int Long/MIN_VALUE -1)))
(assert (= 0 (native.int-division/mod-int Long/MIN_VALUE -1)))"

cp "$here/main.c" "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$scratch/"
definitions=(
  "-DQUOT_FN=native_m0_fn_$quot_index"
  "-DREM_FN=native_m0_fn_$rem_index"
  "-DMOD_FN=native_m0_fn_$mod_index"
  "-DADD_FN=native_m0_fn_$add_index"
  "-DMULTIPLY_FN=native_m0_fn_$multiply_index"
  "-DNEGATE_FN=native_m0_fn_$negate_index"
  "-DKEYWORD_FN=native_m0_fn_$keyword_index"
)
strict=(-std=c17 -pedantic -Wall -Wextra -Werror)

run_compiler() {
  local compiler="$1"
  local output="$2"
  (
    cd "$scratch"
    "$compiler" "${strict[@]}" "${definitions[@]}" -o "$output" \
      module_0.c native_shim.c main.c
    "./$output"
    for mode in zero-quot zero-rem zero-mod overflow-add; do
      if (ulimit -c 0 && "./$output" "$mode") 2>/dev/null; then
        echo "drive.sh: $compiler accepted $mode" >&2
        exit 1
      fi
    done
  )
}

run_compiler gcc probe_gcc
run_compiler "$clang_bin" probe_clang

echo "int-arithmetic: managed parity, Native obligations, strict GCC+Clang, guarded edges, and QBE refusal PASS"
