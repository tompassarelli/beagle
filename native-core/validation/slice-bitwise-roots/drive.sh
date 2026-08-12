#!/usr/bin/env bash
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-bitwise-roots.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-bitwise-roots: $*" >&2
  exit 1
}

for command in awk bb cmp gcc rg; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done

find_qbe() {
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
[[ -n "$qbe_bin" ]] || die "qbe is unavailable"

"$repo/bin/beagle-ast" "$here/fixture.bclj" >"$scratch/fixture.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  "$scratch/fixture.ast.json=beagle:native-core/validation/slice-bitwise-roots/fixture.bclj" \
  "$scratch/fixture.facts"

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
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations c11 slice fold_c17 body_c17 body_slice qbe; do
  target="$scratch/out/native/$module.clj"
  [[ -f "$target" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$target"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$target" >"$target.tmp"
  mv "$target.tmp" "$target"
done

bb -cp "$scratch/out" -e "
(require 'native.body-slice)
(spit \"$scratch/report.txt\"
  (native.body-slice/emit-dual-slice! \"$scratch/fixture.facts\"
    \"native.bitwise-roots\"
    \"beagle:native-core/validation/slice-bitwise-roots/fixture.bclj\"
    \"$scratch\" \"native-bitwise-roots-v0\" \"codec-word\" 1 \"$abi\"))"

report="$scratch/report.txt"
for line in \
  'stage typed-to-native COMPLETE' \
  'materialize OK module_0.h module_0.c' \
  'qbe-stage typed-to-native COMPLETE' \
  'qbe-selected-function codec-word' \
  'qbe-materialize OK module_1.ssa'; do
  rg -Fx "$line" "$report" >/dev/null || die "report is missing: $line"
done
if rg -q '^pending ' "$report"; then
  rg '^pending ' "$report" >&2
  die "fixture left a Native lowering root"
fi

function_index="$(awk '$1 == "lowered" && $3 == "codec-word" {
  sub(/^fn_/, "", $2); print $2
}' "$report")"
[[ "$function_index" =~ ^[0-9]+$ ]] || die "codec-word function index is unresolved"

mkdir -p "$scratch/managed/native" "$scratch/build"
"$repo/bin/beagle-build" "$here/fixture.bclj" \
  "$scratch/managed/native/bitwise_roots.clj" >/dev/null
bb -cp "$scratch/managed" \
  "$here/managed_runner.clj" "$here/corpus.tsv" >"$scratch/managed.out"

cp "$scratch/module_0.h" "$scratch/module_0.c" "$scratch/module_1.ssa" \
  "$here/main.c" "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$scratch/build/"
"$qbe_bin" "$scratch/build/module_1.ssa" >"$scratch/build/module_1.s"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
(
  cd "$scratch/build"
  gcc "${strict[@]}" -DC17_FN="native_m0_fn_$function_index" \
    -c module_0.c -o module_0.o
  gcc "${strict[@]}" -c native_shim.c -o native_shim.o
  gcc "${strict[@]}" -DC17_FN="native_m0_fn_$function_index" \
    -c main.c -o main.o
  gcc -c module_1.s -o module_1.o
  gcc module_0.o module_1.o native_shim.o main.o -o probe
  ./probe "$here/corpus.tsv" >"$scratch/native.out"
)

cmp -s "$scratch/native.out" "$scratch/managed.out" \
  || die "C17/QBE output differs from managed Clojure"
[[ "$(wc -l <"$scratch/native.out")" -eq 12 ]] \
  || die "not all codec-shaped cases ran"

cat "$report"
echo "slice-bitwise-roots: managed/C17/QBE parity across 12 codec-shaped cases PASS"
