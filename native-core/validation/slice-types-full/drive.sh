#!/usr/bin/env bash
# Drive fram:src/fram/types.bgl through the whole native pipeline and emit the
# C17 projection of its record ABI.
#
#   beagle-ast -> source facts -> frozen source program -> typed program
#     -> native program -> 7 obligations -> native.c11 emitters
#
# Re-runnable and byte-stable: every input is regenerated from the selected
# current Fram source.
#
# Env: NATIVE_SLICE_REPO, NATIVE_SLICE_ARTIFACTS, FRAM_CHECKOUT.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-}"
fram_checkout="$("$repo/native-core/validation/fram-checkout.sh")"
src="$fram_checkout/src/fram/types.bgl"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-types-full.XXXXXX")"
[[ -n "$art" ]] || art="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT
mkdir -p "$art"

if [[ ! -f "$src" ]]; then
  echo "drive.sh: upstream Fram source is missing: $src" >&2
  exit 1
fi
"$repo/bin/beagle-ast" "$src" >"$scratch/types.ast.json"
logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
  "$scratch/types.ast.json")"
bb "$here/ast-facts.clj" "$scratch/types.ast.json" "$scratch/types.facts"
cp "$scratch/types.facts" "$art/types.facts"
sha256sum "$src" | cut -d' ' -f1 >"$art/source.sha256"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || { sed -n '1,200p' "$scratch/build.log" >&2; exit 1; }

# The lowering passes rebuild the fact index on every lookup, so a 1300-fact
# module needs a compiling runtime, not the interpreter.
bb -cp "$scratch/out" -e "
(require 'native.slice)
(spit \"$art/report.txt\"
  (native.slice/emit-slice! \"$scratch/types.facts\" \"fram.types\"
    \"$logical\" \"$art\" \"native-slice-types-full-v0\" \"$abi\"))"

cat "$art/report.txt"
