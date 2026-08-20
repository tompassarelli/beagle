#!/usr/bin/env bash
# Drive store:src/store/types.bgl through the whole native pipeline and emit the
# C17 projection of its record ABI.
#
#   beagle-ast -> source facts -> frozen source program -> typed program
#     -> native program -> 7 obligations -> native.c11 emitters
#
# Re-runnable and byte-stable: every input is regenerated from the selected
# current Beagle Store source.
#
# Env: NATIVE_SLICE_REPO, NATIVE_SLICE_ARTIFACTS.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
if [[ "${BEAGLE_NATIVE_COMPILER_BIN+x}" == x ]]; then
  exec "$here/drive-native.sh"
fi
art="${NATIVE_SLICE_ARTIFACTS:-}"
store_checkout="$("$repo/native-core/validation/store-checkout.sh")"
src="$store_checkout/src/store/types.bgl"
module_root="store/src=$store_checkout/src"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-types-full.XXXXXX")"
[[ -n "$art" ]] || art="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT
mkdir -p "$art"

if [[ ! -f "$src" ]]; then
  echo "drive.sh: upstream Beagle Store source is missing: $src" >&2
  exit 1
fi
"$repo/bin/beagle-ast" --module-root "$module_root" \
  "$src" >"$scratch/types.ast.json"
logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
  "$scratch/types.ast.json")"
bb "$here/ast-facts.clj" "$scratch/types.ast.json" "$scratch/types.facts"
types_facts_digest="$(sha256sum "$scratch/types.facts" | awk '{print $1}')"
mkdir "$scratch/types.facts.manifest.segments"
cp "$scratch/types.facts" \
  "$scratch/types.facts.manifest.segments/000000-$types_facts_digest.facts"
printf '%s\n%s\n' 'beagle-source-facts-manifest-v1' \
  "types.facts.manifest.segments/000000-$types_facts_digest.facts" \
  >"$scratch/types.facts.manifest"
cp "$scratch/types.facts" "$art/types.facts"
sha256sum "$src" | cut -d' ' -f1 >"$art/source.sha256"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/simd.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || { sed -n '1,200p' "$scratch/build.log" >&2; exit 1; }

# The lowering passes rebuild the fact index on every lookup, so a 1300-fact
# module needs a compiling runtime, not the interpreter.
bb -cp "$scratch/out" -e "
(require 'native.slice)
(spit \"$art/report.txt\"
  (native.slice/emit-slice! \"$scratch/types.facts.manifest\" \"store.types\"
    \"$logical\" \"$art\" \"native-slice-types-full-v0\" \"$abi\"))"

cat "$art/report.txt"
