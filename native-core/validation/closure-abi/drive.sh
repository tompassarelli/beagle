#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-closure-abi.XXXXXX")"
if [[ "${S6_KEEP_SCRATCH:-0}" == 1 ]]; then
  printf 'closure-abi: scratch %s\n' "$scratch"
else
  trap 'rm -rf "${scratch:?}"' EXIT
fi

fixture="$here/fixture.bgl"
ast="$scratch/fixture.ast.json"
facts="$scratch/fixture.facts.manifest"
interface_digest="$scratch/fixture.interface.sha256"
compiled="$scratch/compiled"
artifacts="$scratch/artifacts"
source "$repo/bin/_beagle-racket"

"$repo/bin/beagle" validate "$fixture"
"$repo/bin/beagle-ast" --interface-sha256-out "$interface_digest" \
  "$fixture" >"$ast"
interface_sha256="$(<"$interface_digest")"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$ast=native-core/validation/closure-abi/fixture.bgl" \
  --interface-sha256 \
  "native-core/validation/closure-abi/fixture.bgl=$interface_sha256" \
  --output "$facts" --include-defs
mkdir -p "$compiled" "$artifacts"

sources=(
  "$repo/native-core/src/native/core.bclj"
  "$repo/native-core/src/native/stages.bclj"
  "$repo/native-core/src/native/lower.bclj"
  "$repo/native-core/src/native/obligations.bclj"
  "$repo/native-core/src/native/simd.bclj"
  "$repo/native-core/src/native/c11.bclj"
  "$repo/native-core/src/native/slice.bclj"
  "$repo/native-core/src/native/fold_c17.bclj"
  "$repo/native-core/src/native/body_c17.bclj"
)
build_args="$scratch/build-args.txt"
for source in "${sources[@]}"; do
  namespace="$(sed -nE 's/^\(ns[[:space:]]+([^[:space:])]+).*/\1/p' \
    "$source" | head -1)"
  output="$compiled/$(printf '%s' "$namespace" | tr '.-' '/_').clj"
  mkdir -p "$(dirname "$output")"
  printf '%s\t%s\n' "$source" "$output" >>"$build_args"
done
export S6_REPO="$repo"
"$RACKET" "$repo/native-core/bin/run-bounded.rkt" 180 5 -- \
  nice -n 19 xargs -a "$build_args" -P 9 -n 2 bash -c \
    '"$S6_REPO/bin/beagle-build" --module-root "native-core/src=$S6_REPO/native-core/src" "$1" "$2"' _ \
  >"$scratch/build.log" 2>&1 || {
    sed -n '1,200p' "$scratch/build.log" >&2
    exit 1
  }
cp "$here/pipeline.clj" "$compiled/native/closure_abi_pipeline.clj"

# Imported match variants are re-exported for the emitted Clojure modules.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$compiled/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations simd c11 slice fold_c17 body_c17 closure_abi_pipeline; do
  emitted="$compiled/native/$module.clj"
  [[ -f "$emitted" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$emitted"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$emitted" >"$emitted.tmp"
  mv "$emitted.tmp" "$emitted"
done

bb -cp "$compiled" -e "
(require 'native.closure-abi-pipeline)
(spit \"$artifacts/report.txt\"
  (native.closure-abi-pipeline/emit! \"$facts\" \"$artifacts\"))"

report="$artifacts/report.txt"
cat "$report"
rg -q '^stage source-freeze ACCEPTED$' "$report"
rg -q '^stage source-to-typed ACCEPTED$' "$report"
rg -q '^stage typed-to-native COMPLETE$' "$report"
rg -q '^obligations PASS$' "$report"
rg -q '^materialize OK module_0.h module_0.c$' "$report"

main_index="$(awk '$1 == "lowered" && $3 == "-main" {
  sub(/^fn_/, "", $2); print $2
}' "$report")"
[[ -n "$main_index" ]] || {
  echo "closure-abi: materialized -main was not found" >&2
  exit 1
}

{
  echo '#include <stdint.h>'
  echo '#include "module_0.h"'
  echo 'int main(void) {'
  echo '  native_arena arena;'
  echo '  native_capability capability = { UINT64_C(1) };'
  echo '  if (!native_arena_init_growable(&arena, (size_t)4096U)) return 2;'
  printf '  int64_t result = native_m0_fn_%s(&arena, &capability);\n' "$main_index"
  echo '  native_arena_destroy(&arena);'
  echo '  return result == INT64_C(0) ? 0 : 1;'
  echo '}'
} >"$scratch/main.c"

gcc -std=c17 -Wall -Wextra -Werror \
  -I"$artifacts" -I"$repo/native-core/shim" \
  "$scratch/main.c" "$artifacts/module_0.c" \
  "$repo/native-core/shim/native_shim.c" -lm -o "$scratch/closure-abi"
"$scratch/closure-abi"

echo "closure-abi: escaping capture, letfn, apply, and variadic packing PASS"
