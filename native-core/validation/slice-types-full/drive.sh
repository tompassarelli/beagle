#!/usr/bin/env bash
# Drive fram:src/fram/types.bgl through the whole native pipeline and emit the
# C17 projection of its record ABI.
#
#   beagle-ast -> source facts -> frozen source program -> typed program
#     -> native program -> 7 obligations -> native.c11 emitters
#
# Re-runnable and byte-stable: every input is regenerated from the vendored
# fram source.
#
# Env: NATIVE_SLICE_REPO, NATIVE_SLICE_ARTIFACTS, FRAM_TYPES,
#      NATIVE_SLICE_COMMITTED_FACTS.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
# Upstream fram sources are vendored under native-core/validation/upstream/fram
# (its MANIFEST records the fram revision and digests); a FRAM_* override still
# points a run at a live checkout. The default is beagle-only ON PURPOSE: a gate
# must not be a function of another repository's working tree.
src="${FRAM_TYPES:-$repo/native-core/validation/upstream/fram/src/fram/types.bgl}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-types-full.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

banner=""
if [[ "${NATIVE_SLICE_COMMITTED_FACTS:-0}" == 1 ]]; then
  # Opt-in only, and it says so in the report: this mode proves the committed
  # projection still lowers, never that it still matches the vendored source.
  [[ -f "$art/types.facts" ]] \
    || { echo "drive.sh: NATIVE_SLICE_COMMITTED_FACTS=1 but no committed $art/types.facts" >&2; exit 1; }
  banner="MODE committed-facts: upstream fram source NOT read; this run does not prove the projection matches the vendored fram source"
  echo "drive.sh: $banner" >&2
  cp "$art/types.facts" "$scratch/types.facts"
elif [[ ! -f "$src" ]]; then
  echo "drive.sh: upstream fram source is missing: $src" >&2
  echo "drive.sh: restore native-core/validation/upstream/fram, point FRAM_TYPES at a fram source, or set NATIVE_SLICE_COMMITTED_FACTS=1 to check only the committed projection" >&2
  exit 1
else
  "$repo/bin/beagle-ast" "$src" >"$scratch/types.ast.json"
  bb "$here/ast-facts.clj" "$scratch/types.ast.json" "$scratch/types.facts"
  if [[ -f "$art/types.facts" ]] && ! cmp -s "$scratch/types.facts" "$art/types.facts"; then
    echo "drive.sh: regenerated projection differs from the committed types.facts" >&2
    exit 1
  fi
  cp "$scratch/types.facts" "$art/types.facts"
  sha256sum "$src" | cut -d' ' -f1 >"$art/source.sha256"
fi

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
    \"fram:src/fram/types.bgl\" \"$art\" \"native-slice-types-full-v0\" \"$abi\"))"

if [[ -n "$banner" ]]; then
  sed -i "1i $banner" "$art/report.txt"
fi
cat "$art/report.txt"
